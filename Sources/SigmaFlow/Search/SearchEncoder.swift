@preconcurrency import CoreML
import Foundation
import Vision

/// Turns lines, descriptions, searches and pictures into vectors, with EmbeddingGemma 2
/// (`EmbeddingGemma2.swift`). The text side stays loaded once used, so a search answers in
/// milliseconds; the picture side is loaded only while pictures are being read.
///
/// Downloaded once (0.9 GB, pinned revision) the first time there is anything to index: the
/// text and picture packages, the token table and the tokenizer. The audio package in the same
/// repository is never fetched. The first load prepares the text model for the Neural Engine,
/// which takes a minute or two once; Core ML keeps the result.
actor SearchEncoder {
    static let shared = SearchEncoder()

    private static let repo = "FluidInference/embeddinggemma-2-coreml"
    private static let revision = "3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4"
    private static let packages = ["EmbeddingGemma2Text", "EmbeddingGemma2Vision"]
    private static var files: [String] {
        ["config.json", "tokenizer.json", "embeddings.bf16", "position_embeddings.f16"]
            + packages.flatMap { package in
                ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
                    .map { "\(package).mlpackage/\($0)" }
            }
    }

    static var folder: URL { ModelFiles.root.appendingPathComponent("EmbeddingGemma2/\(revision)", isDirectory: true) }
    nonisolated static var isDownloaded: Bool { ModelFiles.isReady(folder) }

    private var text: EmbeddingGemma2Text?
    private var vision: EmbeddingGemma2Vision?
    /// One download or load at a time; a second caller waits for the first.
    private var preparing: Task<EmbeddingGemma2Text, Error>?

    private func download() async throws {
        let staging = Self.folder.appendingPathComponent("download", isDirectory: true)
        try await ModelFiles.fetch(repo: Self.repo, revision: Self.revision, files: Self.files, into: staging)
        let fm = FileManager.default
        for package in Self.packages {
            let compiled = try await MLModel.compileModel(at: staging.appendingPathComponent("\(package).mlpackage"))
            let target = Self.folder.appendingPathComponent("\(package).mlmodelc")
            try? fm.removeItem(at: target)
            try fm.moveItem(at: compiled, to: target)
        }
        for file in ["config.json", "tokenizer.json", "embeddings.bf16", "position_embeddings.f16"] {
            let target = Self.folder.appendingPathComponent(file)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: staging.appendingPathComponent(file), to: target)
        }
        try? fm.removeItem(at: staging)
        try ModelFiles.markReady(Self.folder)
        Log.search.info("search model downloaded")
    }

    /// The text model, downloading and loading it the first time.
    private func textModel() async throws -> EmbeddingGemma2Text {
        if let text { return text }
        if let preparing { return try await preparing.value }
        let task = Task<EmbeddingGemma2Text, Error> {
            if !Self.isDownloaded { try await self.download() }
            let started = Date()
            let model = try await EmbeddingGemma2Text(directory: Self.folder)
            Log.search.info("search model loaded in \(Int(Date().timeIntervalSince(started))) s")
            return model
        }
        preparing = task
        defer { preparing = nil }
        let model = try await task.value
        text = model
        return model
    }

    /// Whether a search can be answered by meaning right now, without waiting on a download
    /// or a load: a search typed before then is answered by its exact words alone.
    var isWarm: Bool { text != nil }

    /// Starts the download and load in the background, so the first search is quick.
    func warm() async {
        _ = try? await textModel()
    }

    func query(_ text: String) async throws -> [Float] {
        try await textModel().embed(text, prompt: .searchQuery)
    }

    func documents(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try await textModel().embed(texts, prompt: .document)
    }

    /// How a picture looks, in the same space as the words.
    func picture(_ url: URL) async throws -> [Float] {
        let text = try await textModel()
        if vision == nil { vision = try await EmbeddingGemma2Vision(directory: Self.folder) }
        guard let vision else { throw EmbeddingGemma2Error.predictionFailed("no picture model") }
        let (tokens, count) = try await vision.tokens(for: url)
        return try await text.embed(imageTokens: tokens, count: count)
    }

    /// Lets go of the picture side once the pictures are read; the text side stays for searches.
    func releasePictures() {
        vision = nil
    }
}

/// The words on a picture, read by the Mac itself (Vision): instant and exact for screenshots
/// in Latin letters, where codes like INV-20431 must match to the character. It cannot read
/// Tamil; Gemma's description covers that.
enum PictureText {
    static func read(_ url: URL) async -> String {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(url: url)
            guard (try? handler.perform([request])) != nil else { return "" }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}
