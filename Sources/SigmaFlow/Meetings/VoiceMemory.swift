import Accelerate
import Foundation

/// The voices the user has named, kept so the next meeting starts with those names already
/// on their lines. Hidden on purpose (Gokul, 14 Oct 2026): nothing in the app says a voice
/// was remembered, and there is no setting. Naming a speaker is the only way in.
///
/// One voiceprint per named voice per meeting, in `voiceprints.json` beside the dictionary
/// (not `voices.json`: that one belongs to the old Meetings page and is left alone). A
/// meeting's prints are rebuilt from scratch every time a speaker in it is renamed, so a
/// corrected name replaces the wrong one and an emptied name forgets the voice.
///
/// A wrong name is worse than a number: a voice gets a name only when it is clearly closer
/// to that name than to anyone else, and otherwise stays Speaker 1, 2.
actor VoiceMemory {
    static let shared = VoiceMemory()

    struct Print: Codable, Sendable {
        var name: String
        /// The meeting it was learned from (`key(for:)`), so renaming there replaces it.
        var meeting: String
        var vector: [Float]
    }

    /// Cosine similarity a voice must reach to take a name. Measured 14 Oct 2026 on Gokul's
    /// own recordings: the same person in two meetings a day apart 0.74 to 0.80, in two halves
    /// of one meeting 0.96 to 0.98; two different people in one room 0.57 to 0.68.
    static let sameVoice: Float = 0.72
    /// and how far ahead of the next-closest name it must be.
    static let margin: Float = 0.1
    /// Seconds of talk a voice needs before it is learned: the short ones measured as noise,
    /// unlike anyone.
    static let minimumTalk: Double = 15

    private var prints: [Print]?

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigmaFlow", isDirectory: true)
            .appendingPathComponent("voiceprints.json")
    }

    /// A meeting's identity that survives a rename: when it was recorded.
    nonisolated static func key(for date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }

    private func loaded() -> [Print] {
        if let prints { return prints }
        let read = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([Print].self, from: $0) } ?? []
        prints = read
        return read
    }

    // MARK: Naming

    /// The name for each voice that is clearly someone already named, by cluster id.
    func names(for voiceprints: [String: [Float]]) -> [String: String] {
        let known = loaded()
        guard !known.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for (cluster, vector) in voiceprints {
            var best: [String: Float] = [:]
            for print in known {
                let score = Self.similarity(vector, print.vector)
                best[print.name] = max(best[print.name] ?? -1, score)
            }
            let ranked = best.sorted { $0.value > $1.value }
            guard let top = ranked.first, top.value >= Self.sameVoice else { continue }
            if ranked.count > 1, top.value - ranked[1].value < Self.margin { continue }
            out[cluster] = top.key
        }
        return out
    }

    // MARK: Learning

    /// Replaces everything learned from one meeting with these voices.
    func remember(meeting: String, voices: [(name: String, vector: [Float])]) {
        var all = loaded().filter { $0.meeting != meeting }
        all += voices.map { Print(name: $0.name, meeting: meeting, vector: $0.vector) }
        save(all)
    }

    /// A deleted meeting's voices: forgotten, and handed back so Undo can return them.
    func forget(meetings: Set<String>) -> [Print] {
        let all = loaded()
        let taken = all.filter { meetings.contains($0.meeting) }
        if !taken.isEmpty { save(all.filter { !meetings.contains($0.meeting) }) }
        return taken
    }

    /// Undo of a delete: the voices `forget` took.
    func restore(_ taken: [Print]) {
        guard !taken.isEmpty else { return }
        let keys = Set(taken.map(\.meeting))
        save(loaded().filter { !keys.contains($0.meeting) } + taken)
    }

    private func save(_ all: [Print]) {
        prints = all
        do {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: Self.file, options: .atomic)
        } catch {
            Log.meetings.error("voices not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The last meeting heard for learning, so renaming three speakers in a row diarizes once.
    private var recent: (audio: URL, modified: Date?, sides: [Diarization])?

    /// Learns the named speakers of a meeting from its audio and its current transcript.
    /// The diarizer runs again here rather than at Stop: the folder holds only the audio and
    /// the .md, and what matters is which voice the user's names now sit on.
    func learn(audio: URL, lines: [MeetingLine], duration: Double, meeting: String) async {
        let modified = try? audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var sides: [Diarization]
        if let recent, recent.audio == audio, recent.modified == modified {
            sides = recent.sides
        } else {
            do {
                sides = try await Self.diarizeSides(audio)
            } catch {
                Log.meetings.error("voices not learned: \(error.localizedDescription, privacy: .public)")
                return
            }
            recent = (audio, modified, sides)
        }
        var voices: [(name: String, vector: [Float])] = []
        for side in sides {
            for (cluster, label) in Self.labels(of: side, lines: lines, duration: duration)
            where !MeetingNaming.isNumberedSpeaker(label) {
                if let vector = side.voiceprints[cluster] { voices.append((label, vector)) }
            }
        }
        remember(meeting: meeting, voices: voices)
        Log.meetings.info("voices: \(voices.count) learned from one meeting")
    }

    /// Each side of a recording, diarized the way the transcript was.
    private static func diarizeSides(_ audio: URL) async throws -> [Diarization] {
        guard MeetingAudio.isTwoSided(audio) else {
            return [try await VoiceMatcher.shared.diarize(audio: audio) { _ in }]
        }
        let sides = try MeetingAudio.split(audio)
        defer { try? FileManager.default.removeItem(at: sides.mic.deletingLastPathComponent()) }
        var out = [try await VoiceMatcher.shared.diarize(audio: sides.mic) { _ in }]
        // A call side with a notification on it and no speech has no voices to learn, and
        // must not cost the room its names.
        if MeetingAudio.peak(sides.call) >= MeetingProcessor.silentPeak,
           let call = try? await VoiceMatcher.shared.diarize(audio: sides.call, progress: { _ in }) {
            out.append(call)
        }
        return out
    }

    /// Which transcript label each voice carries: the label whose rows it spends most of its
    /// talking time inside, if that is most of its time at all.
    static func labels(of diarization: Diarization, lines: [MeetingLine], duration: Double) -> [String: String] {
        let ordered = lines.sorted { $0.start < $1.start }
        var spans: [(start: Double, end: Double, label: String)] = []
        for (index, line) in ordered.enumerated() {
            guard let label = line.speaker else { continue }
            let next = index + 1 < ordered.count ? ordered[index + 1].start : duration
            spans.append((line.start, min(next, line.start + MeetingProcessor.hardRowLength + 5), label))
        }
        var talk: [String: Double] = [:]
        var shared: [String: [String: Double]] = [:]
        for segment in diarization.segments {
            talk[segment.clusterID, default: 0] += segment.end - segment.start
            for span in spans {
                let overlap = min(span.end, segment.end) - max(span.start, segment.start)
                if overlap > 0 { shared[segment.clusterID, default: [:]][span.label, default: 0] += overlap }
            }
        }
        var out: [String: String] = [:]
        for (cluster, byLabel) in shared {
            guard let top = byLabel.max(by: { $0.value < $1.value }), let total = talk[cluster],
                  total >= minimumTalk, top.value >= total / 2 else { continue }
            out[cluster] = top.key
        }
        return out
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        let dot = vDSP.dot(a, b)
        let norms = (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()
        return norms > 0 ? dot / norms : -1
    }
}
