import AVFoundation
import FluidAudio
import Foundation

/// Engines and model stores for the catalog models beyond Apple and Parakeet V3.
///
/// Two kinds live here. **Batch** engines (Cohere) accumulate audio while the key is held
/// and transcribe in one pass on release, like `ParakeetEngine`. **Streaming** engines
/// (Parakeet Unified EN, Nemotron) decode while you're still talking, so the overlay shows
/// live text. Each model's loaded instance is cached process-wide, because loading is the
/// expensive part; streaming managers are reset between holds instead of rebuilt.

// MARK: - Download dispatch

/// One place that knows how each catalog model is downloaded.
enum SpeechModelStores {
    static func download(
        _ model: SpeechModelID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let handler: ProgressHandler = { progress in
            onProgress(progress.fractionCompleted)
        }
        switch model {
        case .apple:
            return
        case .parakeetV3:
            _ = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: handler)
        case .parakeet110m:
            _ = try await AsrModels.downloadAndLoad(version: .tdtCtc110m, progressHandler: handler)
        case .parakeetUnified:
            _ = try await UnifiedModels.shared.manager(progressHandler: handler)
        case .nemotron:
            try await NemotronModels.download(progressHandler: handler)
        case .cohere:
            _ = try await CohereModelStore.shared.models(progressHandler: handler)
        }
    }

    /// Loads a model into memory ahead of its first use, so the first hold after launch
    /// doesn't stall.
    static func warm(_ model: SpeechModelID) async throws {
        switch model {
        case .apple:
            return
        case .parakeetV3:
            _ = try await ParakeetModels.shared.manager(version: .v3)
        case .parakeet110m:
            _ = try await ParakeetModels.shared.manager(version: .tdtCtc110m)
        case .parakeetUnified:
            _ = try await UnifiedModels.shared.manager()
        case .nemotron:
            _ = try await NemotronModels.shared.manager()
        case .cohere:
            _ = try await CohereModelStore.shared.models()
        }
    }

    /// The engine for a catalog model. Apple is handled by the caller.
    static func engine(for model: SpeechModelID) -> any TranscriptionEngine {
        switch model {
        case .apple: AppleSpeechEngine()
        case .parakeetV3: ParakeetEngine(version: .v3)
        case .parakeet110m: ParakeetEngine(version: .tdtCtc110m)
        case .parakeetUnified: UnifiedEngine()
        case .nemotron: NemotronEngine()
        case .cohere: CohereEngine()
        }
    }
}

// MARK: - Parakeet Unified EN (streaming)

/// Process-wide cache for the Unified streaming manager. One manager stays loaded and is
/// reset between holds — loading takes seconds, resetting is free.
actor UnifiedModels {
    static let shared = UnifiedModels()

    private var loaded: StreamingUnifiedAsrManager?
    private var loadTask: Task<StreamingUnifiedAsrManager, Error>?

    func manager(progressHandler: ProgressHandler? = nil) async throws -> StreamingUnifiedAsrManager {
        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value }

        let task = Task<StreamingUnifiedAsrManager, Error> {
            let manager = StreamingUnifiedAsrManager()
            try await manager.loadModels(to: nil, configuration: nil, progressHandler: progressHandler)
            return manager
        }
        loadTask = task
        do {
            let manager = try await task.value
            loaded = manager
            return manager
        } catch {
            loadTask = nil
            throw error
        }
    }
}

/// Parakeet Unified EN 0.6B, streaming: your words appear in the overlay as you speak,
/// and the final pass on release matches the model's offline output.
actor UnifiedEngine: TranscriptionEngine {
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation
        // Load (or download) before the user starts talking, not after they release.
        let manager = try await UnifiedModels.shared.manager()
        try await manager.reset()
        await manager.setPartialTranscriptCallback { text in
            continuation.yield(TranscriptionChunk(text: text, isFinal: false))
        }
        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        nonisolated(unsafe) let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }
        do {
            let manager = try await UnifiedModels.shared.manager()
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
        } catch {
            Log.speech.error("Unified streaming: \(error.localizedDescription)")
        }
    }

    func finish() async {
        defer { continuation = nil }
        do {
            let manager = try await UnifiedModels.shared.manager()
            let text = try await manager.finish()
            continuation?.yield(
                TranscriptionChunk(
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    isFinal: true
                )
            )
            continuation?.finish()
        } catch {
            Log.speech.error("Unified streaming failed: \(error.localizedDescription)")
            continuation?.finish(throwing: error)
        }
    }
}

// MARK: - Nemotron Streaming 3.5 (streaming, multilingual)

/// Process-wide cache for the Nemotron multilingual streaming manager.
actor NemotronModels {
    static let shared = NemotronModels()

    /// Chunk tier. 1120 ms keeps the live text responsive for dictation-length holds;
    /// the smaller 560 ms tier degrades punctuation on long sessions (FluidAudio #687).
    static let chunkMs = 1120

    private var loaded: StreamingNemotronMultilingualAsrManager?
    private var loadTask: Task<StreamingNemotronMultilingualAsrManager, Error>?

    /// Fetches the model files without holding anything in memory — the Models page path.
    static func download(progressHandler: ProgressHandler? = nil) async throws {
        _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto",
            chunkMs: chunkMs,
            progressHandler: progressHandler
        )
    }

    func manager(progressHandler: ProgressHandler? = nil) async throws -> StreamingNemotronMultilingualAsrManager {
        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value }

        let task = Task<StreamingNemotronMultilingualAsrManager, Error> {
            let shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
                languageCode: "auto",
                chunkMs: Self.chunkMs,
                progressHandler: progressHandler
            )
            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadFromShared(shared)
            return manager
        }
        loadTask = task
        do {
            let manager = try await task.value
            loaded = manager
            return manager
        } catch {
            loadTask = nil
            throw error
        }
    }
}

/// Nemotron Speech Streaming Multilingual 0.6B: live text in the overlay, language
/// detected automatically from the audio itself.
actor NemotronEngine: TranscriptionEngine {
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation
        let manager = try await NemotronModels.shared.manager()
        await manager.reset()
        await manager.setPartialCallback { text in
            continuation.yield(TranscriptionChunk(text: text, isFinal: false))
        }
        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        nonisolated(unsafe) let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }
        do {
            let manager = try await NemotronModels.shared.manager()
            _ = try await manager.process(audioBuffer: buffer)
        } catch {
            Log.speech.error("Nemotron streaming: \(error.localizedDescription)")
        }
    }

    func finish() async {
        defer { continuation = nil }
        do {
            let manager = try await NemotronModels.shared.manager()
            let text = try await manager.finish()
            continuation?.yield(
                TranscriptionChunk(
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    isFinal: true
                )
            )
            continuation?.finish()
        } catch {
            Log.speech.error("Nemotron streaming failed: \(error.localizedDescription)")
            continuation?.finish(throwing: error)
        }
    }
}

// MARK: - Cohere Transcribe

/// Process-wide cache for the Cohere pipeline and its loaded models.
actor CohereModelStore {
    static let shared = CohereModelStore()

    struct Loaded {
        let pipeline: CoherePipeline
        let models: CoherePipeline.LoadedModels
    }

    private var loaded: Loaded?
    private var loadTask: Task<Loaded, Error>?

    func models(progressHandler: ProgressHandler? = nil) async throws -> Loaded {
        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value }

        let task = Task<Loaded, Error> {
            let base = ModelLibrary.modelsBaseDirectory
            try await ModelHub.download(
                .cohereTranscribeCoreml,
                to: base,
                progressHandler: progressHandler
            )
            let dir = base.appendingPathComponent("cohere-transcribe/q8", isDirectory: true)
            let models = try await CoherePipeline.loadModels(
                encoderDir: dir,
                decoderDir: dir,
                vocabDir: dir
            )
            return Loaded(pipeline: CoherePipeline(), models: models)
        }
        loadTask = task
        do {
            let result = try await task.value
            loaded = result
            return result
        } catch {
            loadTask = nil
            throw error
        }
    }
}

/// Cohere Transcribe, batch. The accuracy ceiling; 14 languages; noticeably slower.
actor CohereEngine: TranscriptionEngine {
    private var samples: [Float] = []
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?
    private let converter = AudioConverter()

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation
        _ = try await CohereModelStore.shared.models()
        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }
        do {
            samples.append(contentsOf: try converter.resampleBuffer(buffer))
        } catch {
            Log.speech.error("Cohere: audio conversion failed — \(error.localizedDescription)")
        }
    }

    func finish() async {
        defer {
            continuation?.finish()
            continuation = nil
            samples.removeAll(keepingCapacity: true)
        }
        guard samples.count >= 1_600 else { return }
        do {
            let store = try await CohereModelStore.shared.models()
            let result = try await store.pipeline.transcribeLong(audio: samples, models: store.models)
            continuation?.yield(
                TranscriptionChunk(
                    text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    isFinal: true
                )
            )
        } catch {
            Log.speech.error("Cohere failed: \(error.localizedDescription)")
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }
}
