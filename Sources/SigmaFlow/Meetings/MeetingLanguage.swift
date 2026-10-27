import Accelerate
import AVFoundation
import FluidAudio
import Foundation

/// What a transcript was heard as. The .md says it on its Language line, and the transcript
/// page shows it beside Speakers (Gokul, 13 Oct 2026, 3A).
enum MeetingLanguage: String, CaseIterable, Sendable {
    case english
    case tamil

    var label: String {
        switch self {
        case .english: "English"
        case .tamil: "Tamil and English"
        }
    }

    init?(label: String) {
        guard let match = Self.allCases.first(where: { $0.label == label }) else { return nil }
        self = match
    }
}

/// Tamil meetings: which parts of a recording go to which model.
///
/// Every meeting is heard by Parakeet first, as before. Then the recording is cut into
/// stretches of 4 to 8 seconds and each is given to `LanguageCheck`. A meeting where at
/// least a tenth of the stretches are surely Tamil is a Tamil meeting: on 13 Oct 2026 the
/// Tamil meeting had 24% and an English one (Indian-accented, the hardest case) had none.
///
/// In a Tamil meeting each stretch then goes one of two ways. Parakeet keeps a stretch when
/// it was confident there, the check did not hear Tamil, and it heard about as many words as
/// IndicConformer did: that is a whole English sentence, and Parakeet writes English best.
/// Every other stretch is IndicConformer's (`TamilSpeech`). In an English meeting nothing
/// changes from before, and IndicConformer is never downloaded.
enum MeetingRouting {
    /// Surely Tamil: the check's chance at or above this.
    private static let sureTamil = 0.9
    /// A Tamil meeting: at least this share of its stretches surely Tamil.
    private static let tamilShare = 0.10
    /// Parakeet keeps a stretch at or above this mean confidence,
    private static let confident: Float = 0.85
    /// when the check gives Tamil less than this,
    private static let notTamil = 0.5
    /// and Parakeet heard at least this share of IndicConformer's word count.
    private static let wordShare = 0.7

    /// The words of one side of a meeting, and what it was heard as. `language` forces the
    /// choice: Transcribe again, English or Tamil and English.
    static func words(
        tokens: [TokenTiming], audio: URL, language forced: MeetingLanguage?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (words: [WordTiming], language: MeetingLanguage) {
        if forced == .english { return (buildWordTimings(from: tokens), .english) }

        let recording = try MeetingSamples(audio)
        let stretches = recording.stretches()
        guard !stretches.isEmpty else { return (buildWordTimings(from: tokens), forced ?? .english) }

        var chances: [Double] = []
        for (index, stretch) in stretches.enumerated() {
            chances.append(try await LanguageCheck.shared.tamilChance(recording.samples(stretch)))
            progress(0.2 * Double(index + 1) / Double(stretches.count))
        }
        let share = Double(chances.filter { $0 >= sureTamil }.count) / Double(chances.count)
        let language = forced ?? (share >= tamilShare ? .tamil : .english)
        Log.meetings.info("meeting: \(Int(share * 100))% of \(stretches.count) stretches surely Tamil, heard as \(language.label, privacy: .public)")
        guard language == .tamil else { return (buildWordTimings(from: tokens), .english) }

        do {
            try await TamilSpeech.shared.prepare { progress(0.2 + 0.4 * $0) }
        } catch where forced == nil {
            // Heard as Tamil but the model can't be had (offline at the first Tamil meeting):
            // today's transcript rather than none. Transcribe again, Tamil and English, retries.
            Log.meetings.error("tamil model unavailable, keeping Parakeet: \(error.localizedDescription, privacy: .public)")
            return (buildWordTimings(from: tokens), .english)
        }

        // Parakeet's words are made from the whole file, then handed out whole: made per
        // stretch, a word across a cut came apart ("fix ed", "information .").
        let parakeetWords = buildWordTimings(from: tokens)
        func middle(_ start: Double, _ end: Double) -> Double { (start + end) / 2 }

        var words: [WordTiming] = []
        var kept = 0
        for (index, stretch) in stretches.enumerated() {
            let from = recording.seconds(stretch.start), to = recording.seconds(stretch.end)
            let inside = tokens.filter { (from..<to).contains(middle($0.startTime, $0.endTime)) }
            let parakeet = parakeetWords.filter { (from..<to).contains(middle($0.startTime, $0.endTime)) }
            let samples = recording.samples(stretch)
            let offset = recording.seconds(stretch.paddedStart)
            let tamil = try await TamilSpeech.shared.words(samples).map {
                WordTiming(word: $0.text, startTime: offset + $0.start, endTime: offset + $0.end)
            }
            let confidence = inside.isEmpty ? 0 : inside.map(\.confidence).reduce(0, +) / Float(inside.count)
            let isEnglish = !parakeet.isEmpty
                && confidence >= confident
                && chances[index] < notTamil
                && Double(parakeet.count) >= wordShare * Double(tamil.count)
            if isEnglish { kept += 1 }
            words += isEnglish ? parakeet : tamil
            progress(0.6 + 0.4 * Double(index + 1) / Double(stretches.count))
        }
        Log.meetings.info("meeting: \(kept) of \(stretches.count) stretches kept as English")
        return (words.sorted { $0.startTime < $1.startTime }, .tamil)
    }
}

/// A meeting's audio as 16 kHz mono, read a stretch at a time so a two-hour recording never
/// sits in memory whole.
///
/// The level is raised so the loudest tenth of the recording sits near -20 dB, with a soft
/// limit on peaks: the 13 Oct meeting sat at -44 dB, too quiet for both models.
final class MeetingSamples {
    struct Stretch {
        /// In samples, where the stretch was cut,
        var start: Int
        var end: Int
        /// and with a tenth of a second either side, which is what the models hear.
        var paddedStart: Int
        var paddedEnd: Int
    }

    private static let rate = Double(TamilSpeech.sampleRate)
    /// 100 ms.
    private static let frame = TamilSpeech.sampleRate / 10

    private let file: AVAudioFile
    private let total: Int
    /// Loudness of every 100 ms, in dB.
    private var levels: [Float] = []
    private var gain: Float = 1

    init(_ url: URL) throws {
        file = try AVAudioFile(forReading: url)
        let ratio = Self.rate / file.processingFormat.sampleRate
        total = Int((Double(file.length) * ratio).rounded(.down))
        try measure()
    }

    func seconds(_ sample: Int) -> Double { Double(sample) / Self.rate }

    /// Stretches of 4 to 8 seconds, each ending at the quietest 100 ms of its last four, and
    /// none of the near-silent ones. Cutting at pauses alone failed on a meeting where people
    /// talk without stopping: most of it counted as one long pause.
    func stretches() -> [Stretch] {
        var out: [Stretch] = []
        var index = 0
        let count = levels.count
        while index < count {
            var next = count
            if count - index > 80 {
                next = ((index + 40)..<(index + 80)).min { levels[$0] < levels[$1] }!
            }
            let slice = levels[index..<next].sorted()
            let loud = slice[min(slice.count - 1, Int(Double(slice.count - 1) * 0.9))]
            if loud > -50 {
                let start = index * Self.frame, end = min(total, next * Self.frame)
                out.append(Stretch(
                    start: start, end: end,
                    paddedStart: max(0, start - Self.frame), paddedEnd: min(total, end + Self.frame)))
            }
            index = next
        }
        return out
    }

    /// One stretch, padded, at the raised level.
    func samples(_ stretch: Stretch) -> [Float] {
        var out = read(from: stretch.paddedStart, count: stretch.paddedEnd - stretch.paddedStart)
        var level = gain
        var count = Int32(out.count)
        out.withUnsafeMutableBufferPointer { values in
            vDSP_vsmul(values.baseAddress!, 1, &level, values.baseAddress!, 1, vDSP_Length(values.count))
            vvtanhf(values.baseAddress!, values.baseAddress!, &count)
        }
        return out
    }

    private func measure() throws {
        var levels: [Float] = []
        var position = 0
        let chunk = Self.frame * 100
        while position < total {
            let samples = read(from: position, count: min(chunk, total - position))
            if samples.isEmpty { break }
            var offset = 0
            samples.withUnsafeBufferPointer { values in
                while offset + Self.frame <= values.count {
                    var square: Float = 0
                    vDSP_measqv(values.baseAddress! + offset, 1, &square, vDSP_Length(Self.frame))
                    levels.append(10 * log10(square + 1e-18))
                    offset += Self.frame
                }
            }
            position += samples.count
        }
        self.levels = levels
        let sorted = levels.sorted()
        if let loud = sorted.isEmpty ? nil : sorted[Int(Double(sorted.count - 1) * 0.9)] {
            gain = powf(10, (-20 - loud) / 20)
        }
    }

    /// Mono 16 kHz samples starting at a 16 kHz position, whatever the file holds.
    private func read(from start: Int, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let source = file.processingFormat
        let ratio = source.sampleRate / Self.rate
        let sourceCount = AVAudioFrameCount((Double(count) * ratio).rounded(.up))
        file.framePosition = AVAudioFramePosition((Double(start) * ratio).rounded(.down))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: sourceCount),
              (try? file.read(into: buffer, frameCount: sourceCount)) != nil,
              let channels = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(source.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        var share = 1 / Float(channelCount)
        mono.withUnsafeMutableBufferPointer { out in
            for channel in 0..<channelCount {
                vDSP_vsma(channels[channel], 1, &share, out.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        guard source.sampleRate != Self.rate else { return Array(mono.prefix(count)) }
        // Another rate: straight-line resampling is plenty for hearing which language it is
        // and for the model, which sees 25 ms windows.
        return (0..<count).map { index in
            let at = Double(index) * ratio
            let low = min(frames - 1, Int(at)), high = min(frames - 1, low + 1)
            let t = Float(at - Double(low))
            return mono[low] * (1 - t) + mono[high] * t
        }
    }
}
