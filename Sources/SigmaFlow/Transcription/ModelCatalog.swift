import Foundation
import Observation

/// The models SigmaFlow can transcribe with. One is active at a time.
///
/// Apple is built into macOS. The rest are open-weight models — downloaded once from
/// Hugging Face, stored under Application Support/FluidAudio/Models, run entirely on
/// this Mac. Curated on purpose: every entry has a distinct job.
enum SpeechModelID: String, CaseIterable, Sendable {
    case apple
    case parakeetV3
    case parakeetUnified
    case nemotron
    case parakeet110m
    case cohere

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .parakeetV3: "Parakeet V3"
        case .parakeetUnified: "Parakeet Unified EN"
        case .nemotron: "Nemotron Streaming 3.5"
        case .parakeet110m: "Parakeet 110M"
        case .cohere: "Cohere Transcribe"
        }
    }

    /// The one-line role, in the app's voice.
    var blurb: String {
        switch self {
        case .apple:
            "Built into macOS. Nothing to download."
        case .parakeetV3:
            "Fast and accurate across European languages."
        case .parakeetUnified:
            "The most accurate English, with punctuation and capitalization built in."
        case .nemotron:
            "Live multilingual transcription. Detects the language on its own."
        case .parakeet110m:
            "Tiny and quick. A good fit when disk space matters."
        case .cohere:
            "The accuracy ceiling. Slower, and a big download."
        }
    }

    var languages: String {
        switch self {
        case .apple: "macOS system languages"
        case .parakeetV3: "25 languages"
        case .parakeetUnified: "English only"
        case .nemotron: "100+ languages"
        case .parakeet110m: "English only"
        case .cohere: "14 languages"
        }
    }

    var sizeText: String {
        switch self {
        case .apple: "0 MB"
        case .parakeetV3: "456 MB"
        case .parakeetUnified: "697 MB"
        case .nemotron: "716 MB"
        case .parakeet110m: "160 MB"
        case .cohere: "1.6 GB"
        }
    }

    /// Whether words appear in the overlay while you speak. Batch models resolve on
    /// release instead.
    var streamsLiveText: Bool {
        switch self {
        case .apple, .parakeetUnified, .nemotron: true
        case .parakeetV3, .parakeet110m, .cohere: false
        }
    }

    /// How the text arrives, as the Models page says it.
    var deliveryText: String {
        streamsLiveText ? "Live as you speak" : "Text after you release"
    }

    /// Which tab of the Models page a model sits on. A model never changes tabs.
    var isEnglishOnly: Bool {
        switch self {
        case .parakeetUnified, .parakeet110m: true
        case .apple, .parakeetV3, .nemotron, .cohere: false
        }
    }

    /// Relative rating across this catalog, 1 to 5 blocks. Not a benchmark: a ranking that
    /// makes the trade-off between the rows legible at a glance.
    var accuracy: Int {
        switch self {
        case .apple: 3
        case .parakeetV3: 4
        case .parakeetUnified: 5
        case .nemotron: 4
        case .parakeet110m: 2
        case .cohere: 5
        }
    }

    /// Relative rating across this catalog, 1 to 5 blocks. Same caveat as `accuracy`.
    var speed: Int {
        switch self {
        case .apple: 5
        case .parakeetV3: 4
        case .parakeetUnified: 4
        case .nemotron: 4
        case .parakeet110m: 5
        case .cohere: 2
        }
    }

    /// Folder under Application Support/FluidAudio/Models where the files land.
    /// Matches FluidAudio's `Repo.folderName` (plus variant subpath where the repo
    /// ships variants) for each model. Nil for Apple.
    var modelFolder: String? {
        switch self {
        case .apple: nil
        case .parakeetV3: "parakeet-tdt-0.6b-v3"
        case .parakeetUnified: "parakeet-unified-en-0.6b"
        case .nemotron: "nemotron-multilingual/multilingual/\(NemotronModels.chunkMs)ms"
        case .parakeet110m: "parakeet-tdt-ctc-110m"
        case .cohere: "cohere-transcribe/q8"
        }
    }
}

/// Download state and disk truth for every model. The Models page reads this; the
/// download actions write it.
@MainActor
@Observable
final class ModelLibrary {
    static let shared = ModelLibrary()

    enum State: Equatable {
        case builtIn
        case notDownloaded
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    private(set) var states: [SpeechModelID: State] = [:]
    private var downloads: [SpeechModelID: Task<Void, Never>] = [:]

    private init() {
        refresh()
    }

    /// Re-reads the disk. Cheap; call whenever the page appears.
    func refresh() {
        for model in SpeechModelID.allCases {
            if case .downloading = states[model] { continue }
            if model == .apple {
                states[model] = .builtIn
            } else {
                states[model] = Self.isOnDisk(model) ? .downloaded : .notDownloaded
            }
        }
    }

    func state(of model: SpeechModelID) -> State {
        states[model] ?? .notDownloaded
    }

    nonisolated static var modelsBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static func isOnDisk(_ model: SpeechModelID) -> Bool {
        guard let folder = model.modelFolder else { return true }
        let dir = modelsBaseDirectory.appendingPathComponent(folder, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    /// Starts the download for one model and tracks its progress.
    func download(_ model: SpeechModelID) {
        guard model != .apple, state(of: model) != .downloaded else { return }
        if case .downloading = state(of: model) { return }
        states[model] = .downloading(0)

        let onProgress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in
                if case .downloading = ModelLibrary.shared.state(of: model) {
                    ModelLibrary.shared.states[model] = .downloading(fraction)
                }
            }
        }

        downloads[model] = Task {
            do {
                try await SpeechModelStores.download(model, onProgress: onProgress)
                guard !Task.isCancelled else { return }
                states[model] = .downloaded
            } catch {
                guard !Task.isCancelled else { return }
                Log.speech.error("Download failed for \(model.rawValue): \(error.localizedDescription)")
                states[model] = .failed("Download failed. Check your connection and try again.")
            }
            downloads[model] = nil
        }
    }

    /// The cross beside a progress line. Whatever landed so far is cleared so the row
    /// goes back to Download rather than counting a half-written folder as installed.
    func cancelDownload(_ model: SpeechModelID) {
        guard case .downloading = state(of: model) else { return }
        downloads[model]?.cancel()
        downloads[model] = nil
        if let folder = model.modelFolder {
            let dir = Self.modelsBaseDirectory.appendingPathComponent(folder, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        }
        states[model] = .notDownloaded
    }

    /// Removes a model's files from disk. The active model falls back to Apple first.
    func delete(_ model: SpeechModelID) {
        guard let folder = model.modelFolder else { return }
        if Settings.shared.activeModel == model {
            Settings.shared.activeModel = .apple
        }
        let dir = Self.modelsBaseDirectory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        states[model] = .notDownloaded
    }
}
