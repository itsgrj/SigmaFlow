import FluidAudio
import Foundation

/// A stretch of one voice, from the diarizer.
struct VoiceSegment: Sendable, Hashable {
    var clusterID: String
    var start: Double
    var end: Double
}

/// Who spoke when, and what each voice sounds like. A diarization of one recording: the
/// stretches, and one voiceprint per voice, keyed like the stretches' `clusterID`.
struct Diarization: Sendable {
    var segments: [VoiceSegment] = []
    var voiceprints: [String: [Float]] = [:]
}

/// Speaker diarization on this Mac: which voice was talking when. Voices are told apart
/// by how they sound; the transcript calls them Speaker 1, 2, 3 in the order they first
/// speak, unless `VoiceMemory` knows the voice by a name the user gave it.
///
/// FluidAudio's offline diarizer, not the live one the earlier Meetings code used: it reads
/// the whole recording before deciding who is who, which a finished meeting allows, and it
/// streams the file from disk instead of holding two hours of samples in memory. On the
/// 28 Sep 2026 meeting the live one put the two people who did most of the talking under
/// one label; this one told them apart.
///
/// The models are loaded once and kept; each meeting gets its own manager, because the
/// manager is a plain class and two meetings must never share one.
actor VoiceMatcher {
    static let shared = VoiceMatcher()

    private var models: OfflineDiarizerModels?

    private func loadModels() async throws -> OfflineDiarizerModels {
        if let models { return models }
        // Downloads once (a few tens of MB), then loads from Application Support/FluidAudio.
        let loaded = try await OfflineDiarizerModels.load()
        models = loaded
        return loaded
    }

    /// Diarizes an audio file, oldest segment first.
    func diarize(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Diarization {
        let models = try await loadModels()
        return try await Self.diarize(audio: audio, models: models, progress: progress)
    }

    /// Off the actor: the manager is created, used and dropped inside this one call.
    private nonisolated static func diarize(
        audio: URL, models: OfflineDiarizerModels, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Diarization {
        let manager = OfflineDiarizerManager()
        manager.initialize(models: models)
        let result = try await manager.process(audio) { done, total in
            progress(total > 0 ? Double(done) / Double(total) : 0)
        }
        let segments = result.segments
            .map { VoiceSegment(clusterID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
        Log.meetings.info("diarizer: \(segments.count) segments, \(Set(segments.map(\.clusterID)).count) voices")
        // One voiceprint per voice: the centre of that voice's cluster, which the offline
        // diarizer hands back for exactly this kind of use downstream.
        return Diarization(segments: segments, voiceprints: result.speakerDatabase ?? [:])
    }
}
