import FluidAudio
import Foundation

/// Turns a meeting recording into transcript lines, entirely on this Mac.
///
/// Two passes over the same file, then a join:
/// 1. Parakeet V3 hears the whole recording in one go and returns every word with its time.
///    One pass, not one per speaker stretch: a model given the whole recording has the
///    context to get words right, and slicing into short stretches is how the earlier
///    version ended up with empty transcripts.
/// 2. The diarizer, separately, says which voice was talking when.
/// 3. Each word goes to the voice talking at its moment, and words become rows: a new row
///    when the speaker changes, or when a row has run long enough that its timestamp would
///    stop being useful for finding a moment.
///
/// Parakeet V3 rather than the Models page choice: it is the model built for long batch
/// audio, it follows 25 languages, and it is the one the Meetings page has always used.
///
/// A call (a two-sided file, `MeetingAudio`) runs the above on each side separately, and
/// both sides are split into voices: the microphone can hear a whole room, not just the
/// user. A room meeting becomes two-sided whenever the Mac plays anything at all, so
/// naming the microphone side after the user put four people under one name (14 Oct
/// 2026). Everyone is Speaker 1, 2, 3, numbered across both sides in the order they first
/// speak, and the microphone's words that merely echo the call's are dropped.
///
/// Between hearing and the join, `MeetingRouting` listens for Tamil. A Tamil meeting's words
/// come from IndicConformer, except whole English sentences, which stay Parakeet's. A meeting
/// is Tamil when either side is.
enum MeetingProcessor {
    /// The rows, and what the meeting was heard as.
    struct Transcript: Sendable {
        var lines: [MeetingLine]
        var language: MeetingLanguage
        /// Voices told apart. Not the number of labels: two voices can carry one name.
        var speakers: Int
    }

    /// A row ends at the first sentence end after this many seconds,
    private static let softRowLength: Double = 25
    /// and wherever it is after this many.
    static let hardRowLength: Double = 45
    /// A silence this long starts a new row: someone else is about to talk.
    private static let pauseBreak: Double = 1.5

    enum Failure: LocalizedError {
        case tooShort
        case nothingHeard

        var errorDescription: String? {
            switch self {
            case .tooShort: "The recording is too short to transcribe."
            case .nothingHeard: "Nothing was heard."
            }
        }
    }

    /// A call side quieter than this all the way through is empty: no call, or the
    /// permission to hear it was refused.
    static let silentPeak: Float = 0.01

    /// `language` forces what the meeting is heard as (Transcribe again); nil decides by ear.
    static func transcribe(
        audio: URL, language: MeetingLanguage? = nil, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        guard MeetingAudio.isTwoSided(audio) else {
            return try await transcribeRoom(audio, language: language, progress: progress)
        }

        // A call: the microphone on the left, the call on the right. Each side's voices
        // are told apart on that side alone, then numbered together.
        let sides = try MeetingAudio.split(audio)
        defer { try? FileManager.default.removeItem(at: sides.mic.deletingLastPathComponent()) }

        var (mine, heardAs) = try await heardWords(sides.mic, language: language) { progress(0.02 + $0 * 0.28) }
        var lines: [MeetingLine] = []
        var names: [String: String] = [:]

        if MeetingAudio.peak(sides.call) >= silentPeak {
            let (theirs, theirLanguage) = try await heardWords(sides.call, language: language) { progress(0.3 + $0 * 0.25) }
            if theirLanguage == .tamil { heardAs = .tamil }
            if !theirs.isEmpty {
                mine = withoutEcho(mine, heard: theirs)
                let voices = await voices(audio: sides.call, side: "call") { progress(0.55 + $0 * 0.2) }
                lines = rows(words: theirs, segments: voices.diarization.segments, side: "call")
                names.merge(voices.names) { a, _ in a }
            }
        }
        if !mine.isEmpty {
            let voices = await voices(audio: sides.mic, side: "mic") { progress(0.75 + $0 * 0.2) }
            lines += rows(words: mine, segments: voices.diarization.segments, side: "mic")
            names.merge(voices.names) { a, _ in a }
        }
        progress(0.97)
        guard !lines.isEmpty else { throw Failure.nothingHeard }
        return transcript(lines, names: names, language: heardAs)
    }

    /// A meeting in a room: one microphone, every voice told apart by sound.
    private static func transcribeRoom(
        _ audio: URL, language: MeetingLanguage?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        let (words, heardAs) = try await heardWords(audio, language: language) { progress(0.02 + $0 * 0.53) }
        guard !words.isEmpty else { throw Failure.nothingHeard }
        let voices = await voices(audio: audio, side: "room") { fraction in
            progress(0.55 + fraction * 0.4)
        }
        progress(0.97)
        return transcript(
            rows(words: words, segments: voices.diarization.segments, side: "room"), names: voices.names, language: heardAs)
    }

    private static func transcript(_ lines: [MeetingLine], names: [String: String], language: MeetingLanguage) -> Transcript {
        Transcript(
            lines: numbered(lines, names: names), language: language,
            speakers: Set(lines.compactMap(\.speaker)).count)
    }

    /// Every word heard in a file, with its time: Parakeet V3 over the whole file, then the
    /// Tamil stretches, if any, heard again by IndicConformer.
    private static func heardWords(
        _ audio: URL, language: MeetingLanguage?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (words: [WordTiming], language: MeetingLanguage) {
        progress(0)
        let manager = try await ParakeetModels.shared.manager(version: .v3)
        progress(0.05)
        var state = try TdtDecoderState()
        let heard = try await manager.transcribe(audio, decoderState: &state)
        progress(0.4)
        Log.meetings.info("meeting: \(heard.tokenTimings?.count ?? 0) tokens heard in \(heard.processingTime, format: .fixed(precision: 1))s")
        return try await MeetingRouting.words(tokens: heard.tokenTimings ?? [], audio: audio, language: language) {
            progress(0.4 + $0 * 0.6)
        }
    }

    /// Without headphones the microphone also hears the call through the speakers, so the
    /// other people's words turn up a second time on the user's side. A word on the user's
    /// side that the call side also has, at the same moment, is that echo, and goes. Word by
    /// word, because one row can hold the user's own sentence and an echo side by side.
    static func withoutEcho(_ mine: [WordTiming], heard theirs: [WordTiming]) -> [WordTiming] {
        func plain(_ word: String) -> String {
            String(word.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let window = 1.0
        let call = theirs.map { (time: ($0.startTime + $0.endTime) / 2, word: plain($0.word)) }
        return mine.filter { word in
            let time = (word.startTime + word.endTime) / 2
            let text = plain(word.word)
            guard !text.isEmpty else { return true }
            return !call.contains { abs($0.time - time) <= window && $0.word == text }
        }
    }

    /// Who spoke when, and the names of any voices already known, keyed as `rows` keys
    /// them. Failing here must not lose the meeting: the transcript lands without speaker
    /// labels instead.
    private static func voices(
        audio: URL, side: String, progress: @escaping @Sendable (Double) -> Void
    ) async -> (diarization: Diarization, names: [String: String]) {
        do {
            let diarization = try await VoiceMatcher.shared.diarize(audio: audio, progress: progress)
            let known = await VoiceMemory.shared.names(for: diarization.voiceprints)
            return (diarization, Dictionary(uniqueKeysWithValues: known.map { ("\(side)/\($0.key)", $0.value) }))
        } catch {
            Log.meetings.error("diarizer failed, transcript without speakers: \(error.localizedDescription)")
            return (Diarization(), [:])
        }
    }

    // MARK: Words into rows

    /// Rows labelled with the diarizer's own cluster, kept apart per side: two diarizer runs
    /// both call their first voice the same thing. `numbered` turns these into labels.
    static func rows(words: [WordTiming], segments: [VoiceSegment], side: String) -> [MeetingLine] {
        func key(for cluster: String?) -> String? { cluster.map { "\(side)/\($0)" } }

        var lines: [MeetingLine] = []
        var current: (start: Double, speaker: String?, words: [String])?
        var lastEnd: Double = 0

        for word in words {
            defer { lastEnd = word.endTime }
            let speaker = key(for: cluster(at: word, in: segments))
            if let row = current {
                let elapsed = word.startTime - row.start
                let endsSentence = row.words.last.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") } ?? false
                let changes = speaker != row.speaker
                    || word.startTime - lastEnd >= pauseBreak
                    || (elapsed >= softRowLength && endsSentence)
                    || elapsed >= hardRowLength
                if changes {
                    lines.append(MeetingLine(start: row.start, speaker: row.speaker, text: row.words.joined(separator: " ")))
                    current = (word.startTime, speaker, [word.word])
                } else {
                    current?.words.append(word.word)
                }
            } else {
                current = (word.startTime, speaker, [word.word])
            }
        }
        if let row = current {
            lines.append(MeetingLine(start: row.start, speaker: row.speaker, text: row.words.joined(separator: " ")))
        }
        return lines
    }

    /// Oldest row first, and Speaker 1, 2, 3 in the order voices first speak, not whichever
    /// cluster the diarizer happened to call 1. A remembered voice takes its name instead,
    /// and still uses up its number, so the next new voice is Speaker 3 after two names.
    static func numbered(_ lines: [MeetingLine], names: [String: String] = [:]) -> [MeetingLine] {
        var numbers: [String: Int] = [:]
        return lines.sorted { $0.start < $1.start }.map { line in
            var line = line
            if let key = line.speaker {
                if numbers[key] == nil { numbers[key] = numbers.count + 1 }
                line.speaker = names[key] ?? numbers[key].map(MeetingNaming.speaker)
            }
            return line
        }
    }

    /// The voice talking at the middle of a word, or the nearest voice when the word falls
    /// in a gap between segments.
    private static func cluster(at word: WordTiming, in segments: [VoiceSegment]) -> String? {
        guard !segments.isEmpty else { return nil }
        let middle = (word.startTime + word.endTime) / 2
        if let inside = segments.first(where: { $0.start <= middle && middle <= $0.end }) {
            return inside.clusterID
        }
        return segments.min { distance(middle, $0) < distance(middle, $1) }?.clusterID
    }

    private static func distance(_ time: Double, _ segment: VoiceSegment) -> Double {
        time < segment.start ? segment.start - time : time - segment.end
    }
}
