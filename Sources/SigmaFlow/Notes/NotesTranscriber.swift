import Accelerate
import AVFoundation
import FluidAudio
import Foundation

/// One line of live notes: where it starts in the recording, and what was said.
struct NoteLine: Identifiable, Hashable, Sendable {
    enum Language: Hashable, Sendable {
        /// Parakeet's words, as they came.
        case english
        /// Heard as Tamil while still being spoken: its English guess is hidden, grey blocks
        /// fill in for the words to come, until the line ends and IndicConformer hears it.
        case tamilPending
        /// IndicConformer's words for the whole line.
        case tamil
    }

    let id: Int
    var start: Double
    var text: String
    var language: Language = .english
    /// Seconds of the line heard so far: what a Tamil line's blocks fill in to.
    var length: Double = 0
    /// When a Tamil line's words landed, so it comes in once and not again on a scroll.
    var landed: Date?
}

/// The live words of a notes session, in English and Tamil (docs/mockups/live-notes.html).
///
/// **Lines follow the voice, not the words.** Silero VAD opens a line when someone starts
/// talking and closes it after a second of silence (Gokul, 16 Oct 2026). Tested on a real
/// Tamil meeting, the English model wrote nothing at all for long Tamil stretches, so lines
/// made from its words left whole minutes out.
///
/// English comes from Parakeet Unified EN, streaming, with its own model copy: dictation
/// keeps the shared one (`UnifiedModels`), and a streaming manager holds one conversation's
/// state, so two of them can't share it. Each word goes into the line it was spoken in.
/// Loaded when notes open, released at Stop.
///
/// Tamil comes a line at a time, the Meetings way (`MeetingRouting`). Once a line has ended
/// and the English model has caught up with it, its audio goes to `LanguageCheck`; a line
/// that is Tamil is heard again whole by IndicConformer (`TamilSpeech`) and its English
/// guess is replaced. While a line is spoken it is checked every 2.5 s; once surely Tamil,
/// its English guess gives way to grey blocks until the Tamil lands.
actor NotesTranscriber {
    /// A silence this long ends a line: someone else is about to talk. A second, shorter
    /// than a meeting's 1.5 (Gokul, 16 Oct 2026).
    static let pauseBreak: Double = 1.0
    /// A line ends at the first sentence end after this many seconds, and wherever it is
    /// after the second: shorter than a meeting's rows, because a long one is a wall of
    /// text in a card this narrow. The meeting it becomes is transcribed again anyway.
    static let softLineLength: Double = 12
    static let hardLineLength: Double = 20

    /// Surely Tamil: the check's chance at or above this (`MeetingRouting`'s sureTamil).
    private static let sureTamil = 0.9
    /// Maybe Tamil: at or above this, a line is Tamil when Parakeet was also unsure of it,
    private static let maybeTamil = 0.5
    /// below this mean confidence (`MeetingRouting`'s confident). A line it wrote nothing
    /// for counts as unsure.
    private static let confident: Float = 0.85
    /// The early check listens this far into a line, and again every as much more while
    /// it goes on: 2.5 s is often too little to tell (a line that was Tamil at 0.93 whole
    /// scored 0.00 at 2.5 s), and a check costs a few hundredths of a second.
    private static let earlyCheck: Double = 2.5
    /// How long after a line ends its last English words can still arrive: the streaming
    /// model hears about a second behind.
    private static let catchUp: Double = 2.0
    /// A word this far before a line's start still belongs to it.
    private static let slack: Double = 0.5
    /// Audio kept either side of a line when it is checked and heard.
    private static let lead = 0.25, tail = 0.35
    /// Speech probability that opens a line. Silero's own default is 0.85, which missed
    /// quiet voices across a room.
    private static let voiceThreshold: Float = 0.5

    private let onLines: @Sendable (_ lines: [NoteLine], _ revision: Int) -> Void
    private var manager: StreamingUnifiedAsrManager?
    private var vad: VadManager?
    private var vadState = VadStreamState.initial()
    private var vadPending: [Float] = []
    private var lines: [NoteLine] = []
    private var revision = 0
    /// The line being spoken, if anyone is speaking.
    private var open: Int?
    /// Where each ended line ends.
    private var ends: [Int: Double] = [:]
    /// The line the last word went to: the rest of a word ("omer" after "cust") follows it.
    private var lastLine: Int?
    /// Lines heard as surely Tamil so far. From the second on, the conversation is Tamil and
    /// every line is heard the way a Tamil meeting's stretches are.
    private var sureTamilLines = 0
    /// Lines decided as English before the conversation was known to be Tamil, kept so they
    /// can be heard again once it is: the first line of a Tamil conversation was lost.
    private var leftEnglish: [Int: Tally] = [:]

    /// Per line not yet decided: its words' confidence, where it ends, whether the early
    /// check ran.
    private struct Tally {
        var confidence: Float = 0
        var count = 0
        var end: Double?
        /// How much of the line the next early check waits for.
        var nextCheck = NotesTranscriber.earlyCheck
    }
    private var tallies: [Int: Tally] = [:]
    /// Lines being decided, and the work deciding them.
    private var deciding: [Int: Task<Void, Never>] = [:]

    /// The recording since the oldest line not yet decided, 16 kHz mono.
    private var samples: [Float] = []
    private var samplesStart: Double = 0
    private var heard: Double = 0
    private static let rate = Double(TamilSpeech.sampleRate)

    /// `onLines` gets every change, numbered: decisions finish out of order, and a caller
    /// keeps only the newest.
    init(onLines: @escaping @Sendable (_ lines: [NoteLine], _ revision: Int) -> Void) {
        self.onLines = onLines
    }

    /// Loads the models (downloading them if they never were). Seconds the first time.
    func prepare() async throws {
        guard manager == nil else { return }
        let manager = StreamingUnifiedAsrManager()
        try await manager.loadModels(to: nil, configuration: nil, progressHandler: nil)
        try await manager.reset()
        vad = try await VadManager(config: VadConfig(defaultThreshold: Self.voiceThreshold))
        vadState = VadStreamState.initial()
        self.manager = manager
    }

    /// Feeds one buffer, already 16 kHz mono.
    func feed(_ chunk: AudioChunk) async {
        guard let manager else { return }
        nonisolated(unsafe) let buffer = chunk.buffer
        guard let channel = buffer.floatChannelData?[0] else { return }
        let incoming = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        samples.append(contentsOf: incoming)
        heard += Double(incoming.count) / Self.rate

        await listen(incoming)
        do {
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
        } catch {
            Log.speech.error("notes: \(error.localizedDescription, privacy: .public)")
        }
        place(await manager.consumeTokenTimings())

        // A line spoken without a breath still ends, so it fits the card and the models.
        if let open, heard - lines[open].start >= Self.hardLineLength {
            close(open, at: heard)
            begin(at: heard)
        }
        checkEarly()
        decideCaughtUp()
        trim()
        publish()
    }

    /// Flushes what the models still hold, decides every line left, and lets them go.
    func finish() async -> [NoteLine] {
        if let manager {
            _ = try? await manager.finish()
            place(await manager.consumeTokenTimings())
            await manager.cleanup()
            self.manager = nil
        }
        vad = nil
        if let open { close(open, at: heard) }
        for id in tallies.keys { decide(id) }
        while let task = deciding.values.first {
            await task.value
        }
        return visible
    }

    // MARK: Lines

    /// The voice: a line opens when speech starts and closes after a second of silence.
    private func listen(_ incoming: [Float]) async {
        guard let vad else { return }
        vadPending += incoming
        let config = VadSegmentationConfig(minSilenceDuration: Self.pauseBreak, speechPadding: 0.1)
        while vadPending.count >= VadManager.chunkSize {
            let piece = Array(vadPending.prefix(VadManager.chunkSize))
            vadPending.removeFirst(VadManager.chunkSize)
            guard let result = try? await vad.processStreamingChunk(
                piece, state: vadState, config: config, returnSeconds: true) else { continue }
            vadState = result.state
            guard let event = result.event, let time = event.time else { continue }
            if event.isStart, open == nil {
                begin(at: time)
            } else if event.isEnd, let open {
                close(open, at: max(time, lines[open].start))
            }
        }
    }

    /// A new line. `speaking`: the voice detector opened it and will close it; a line a
    /// word opened (the detector missed a quiet voice) ends where its words end.
    private func begin(at time: Double, speaking: Bool = true) {
        lines.append(NoteLine(id: lines.count, start: time, text: ""))
        tallies[lines.count - 1] = Tally()
        if speaking { open = lines.count - 1 }
    }

    private func close(_ id: Int, at time: Double) {
        if tallies[id] != nil { tallies[id]?.end = time }
        ends[id] = time
        if open == id { open = nil }
    }

    /// The line a word spoken at `time` belongs to, or nil when it starts a new one.
    private func line(for time: Double) -> Int? {
        if let open, time >= lines[open].start - Self.slack { return open }
        guard let id = lines.lastIndex(where: { $0.start - Self.slack <= time }) ?? (lines.isEmpty ? nil : 0)
        else { return nil }
        // Well past where that line ended: someone spoke without the detector noticing.
        if let end = ends[id], time > end + Self.pauseBreak { return nil }
        return id
    }

    /// Each word goes into the line it was spoken in. A word with no line (the voice
    /// detector missed a quiet start) opens one.
    private func place(_ tokens: [TokenTiming]) {
        for token in tokens where !token.token.isEmpty && token.token != "<blank>" && token.token != "<pad>" {
            let time = token.startTime
            let startsWord = token.token.hasPrefix(" ")
            if !startsWord, let lastLine, lines[lastLine].language != .tamil {
                add(token, to: lastLine)
                continue
            }
            guard var id = line(for: time) else {
                begin(at: time, speaking: false)
                close(lines.count - 1, at: token.endTime)
                add(token, to: lines.count - 1)
                continue
            }
            // A line already heard as Tamil has its words; late English guesses are dropped.
            if lines[id].language == .tamil { continue }
            // A long line ends at a sentence end, and the next word starts the next one.
            if id == open, startsWord, time - lines[id].start >= Self.softLineLength,
               let last = lines[id].text.last, ".?!".contains(last) {
                close(id, at: time)
                begin(at: time)
                id = lines.count - 1
            }
            add(token, to: id)
        }
    }

    private func add(_ token: TokenTiming, to id: Int) {
        lastLine = id
        let piece = lines[id].text.isEmpty ? token.token.trimmingCharacters(in: .whitespaces) : token.token
        lines[id].text += piece
        // An ended line that still gets words ends where they do.
        if id != open, let end = ends[id], token.endTime > end {
            ends[id] = token.endTime
            if tallies[id]?.end != nil, deciding[id] == nil { tallies[id]?.end = token.endTime }
        }
        guard tallies[id] != nil else { return }
        tallies[id]?.confidence += token.confidence
        tallies[id]?.count += 1
    }

    /// What the card shows: a line with nothing to say yet (noise, or a voice still
    /// unheard) stays out of sight.
    private var visible: [NoteLine] {
        lines.filter { !$0.text.isEmpty || $0.language == .tamilPending }.map { line in
            var line = line
            let end = line.id == open ? heard : (ends[line.id] ?? tallies[line.id]?.end ?? heard)
            line.length = max(0, end - line.start)
            return line
        }
    }

    private func publish() {
        revision += 1
        onLines(visible, revision)
    }

    // MARK: Tamil

    /// While a line is spoken, every 2.5 s: if it is surely Tamil already, hide the English
    /// guess now rather than show it and swap it later.
    private func checkEarly() {
        guard let id = open, lines[id].language == .english, let tally = tallies[id],
              heard - lines[id].start >= tally.nextCheck else { return }
        tallies[id]?.nextCheck = heard - lines[id].start + Self.earlyCheck
        guard let audio = Self.raised(slice(from: lines[id].start - Self.lead, to: heard)) else { return }
        Task {
            guard let chance = try? await LanguageCheck.shared.tamilChance(audio), chance >= Self.sureTamil else { return }
            self.hold(id)
        }
    }

    private func hold(_ id: Int) {
        // Not once the line is decided: by then it has its final words.
        guard tallies[id] != nil, deciding[id] == nil, lines[id].language == .english else { return }
        lines[id].language = .tamilPending
        publish()
        // The line will want IndicConformer when it ends; load it now.
        Task { try? await TamilSpeech.shared.prepare { _ in } }
    }

    /// Lines that ended long enough ago for their last English words to have arrived.
    private func decideCaughtUp() {
        for (id, tally) in tallies {
            if let end = tally.end, heard >= end + Self.catchUp { decide(id) }
        }
    }

    /// In a Tamil conversation, English stays when it heard at least this share of
    /// IndicConformer's word count (`MeetingRouting`'s wordShare).
    private static let wordShare = 0.7

    /// A line has ended: hear it for Tamil, and replace its words if it is.
    private func decide(_ id: Int) {
        guard deciding[id] == nil, let tally = tallies[id] else { return }
        let end = tally.end ?? heard
        let audio = Self.raised(slice(from: lines[id].start - Self.lead, to: end + Self.tail)) ?? []
        let confidence = tally.count > 0 ? tally.confidence / Float(tally.count) : 0
        let englishWords = lines[id].text.split(separator: " ").count
        if sureTamilLines < 2 { leftEnglish[id] = tally }
        let tamilConversation = sureTamilLines >= 2
        deciding[id] = Task {
            var tamil: String?
            var sure = false
            if audio.count >= TamilSpeech.sampleRate / 2,
               let chance = try? await LanguageCheck.shared.tamilChance(audio) {
                sure = chance >= Self.sureTamil
                let maybe = sure || (chance >= Self.maybeTamil && confidence < Self.confident)
                if maybe || tamilConversation {
                    do {
                        try await TamilSpeech.shared.prepare { _ in }
                        let words = try await TamilSpeech.shared.words(audio)
                        // In a Tamil conversation English is kept only when it is a whole,
                        // confident English sentence (`MeetingRouting`'s rule).
                        let english = englishWords > 0 && confidence >= Self.confident && chance < Self.maybeTamil
                            && Double(englishWords) >= Self.wordShare * Double(words.count)
                        if !words.isEmpty, maybe || !english { tamil = words.map(\.text).joined(separator: " ") }
                    } catch {
                        // Offline at the first Tamil line: the English guess stays.
                        Log.speech.error("notes: tamil unavailable: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            self.settle(id, tamil: tamil, sure: sure)
        }
    }

    private func settle(_ id: Int, tamil: String?, sure: Bool) {
        deciding[id] = nil
        tallies[id] = nil
        if tamil != nil { leftEnglish[id] = nil }
        if sure {
            sureTamilLines += 1
            // The conversation has just turned Tamil: hear again what was left as English,
            // while its audio is still kept.
            if sureTamilLines == 2 {
                for (earlier, tally) in leftEnglish where tallies[earlier] == nil {
                    tallies[earlier] = tally
                    decide(earlier)
                }
                leftEnglish = [:]
            }
        }
        if let tamil {
            lines[id].text = tamil
            lines[id].language = .tamil
            lines[id].landed = Date()
        } else if lines[id].language == .tamilPending {
            lines[id].language = .english
        }
        publish()
    }

    // MARK: Audio

    /// A line at the level the models hear best: its loudest tenth near -20 dB, peaks
    /// softly limited, as `MeetingSamples` does for a whole meeting (the 13 Oct meeting sat
    /// at -44 dB, too quiet for both). Nil when even its loudest tenth is under -50 dB:
    /// that is no voice at all.
    private static func raised(_ samples: [Float]) -> [Float]? {
        let frame = TamilSpeech.sampleRate / 10
        guard samples.count >= frame else { return nil }
        var levels: [Float] = []
        samples.withUnsafeBufferPointer { values in
            var offset = 0
            while offset + frame <= values.count {
                var square: Float = 0
                vDSP_measqv(values.baseAddress! + offset, 1, &square, vDSP_Length(frame))
                levels.append(10 * log10(square + 1e-18))
                offset += frame
            }
        }
        let sorted = levels.sorted()
        let loud = sorted[Int(Double(sorted.count - 1) * 0.9)]
        guard loud > -50 else { return nil }
        var gain = powf(10, (-20 - loud) / 20)
        var out = samples
        var count = Int32(out.count)
        out.withUnsafeMutableBufferPointer { values in
            vDSP_vsmul(values.baseAddress!, 1, &gain, values.baseAddress!, 1, vDSP_Length(values.count))
            vvtanhf(values.baseAddress!, values.baseAddress!, &count)
        }
        return out
    }

    private func slice(from: Double, to: Double) -> [Float] {
        let first = max(0, Int(((from - samplesStart) * Self.rate).rounded(.down)))
        let last = min(samples.count, Int(((to - samplesStart) * Self.rate).rounded(.up)))
        return first < last ? Array(samples[first..<last]) : []
    }

    /// Keeps only what a line still to be decided may need: an hour of notes must not hold
    /// an hour of audio. Trimmed in steps of at least 30 s, so it is rarely done.
    private func trim() {
        let oldestOpen = tallies.keys.map { lines[$0].start }.min() ?? heard
        let keepFrom = oldestOpen - Self.lead - 1
        let drop = min(samples.count, Int(((keepFrom - samplesStart) * Self.rate).rounded(.down)))
        guard drop >= Int(Self.rate) * 30 else { return }
        samples.removeFirst(drop)
        samplesStart += Double(drop) / Self.rate
    }
}
