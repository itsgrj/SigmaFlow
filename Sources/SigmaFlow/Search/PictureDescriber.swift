import Cmlx
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Writes down what is in a conversation's photo or screenshot, so search can find it by its
/// words (Gokul, 18 Oct 2026; docs/mockups/picture-search.html). Google's Gemma 4 E2B (Gemma
/// terms of use), 4-bit, in MLX on the GPU, all on this Mac.
///
/// Chosen on the 18 Oct test (32 pictures, 27 searches): with these descriptions search found
/// 26, as many as the bigger E4B, in half the time, and it copied a Tamil chat exactly where
/// the Mac's own text reading saw gibberish. About 2 s a picture, 4 GB while loaded; loaded
/// only while pictures are being read, then let go.
///
/// Two downloads, the first time a conversation has pictures: the model (3.3 GB) and MLX's
/// GPU kernels (64 MB, from the Python package of the exact MLX version mlx-swift 0.32.3 is
/// built on). The kernels can't be built here: SwiftPM on the command line cannot compile
/// Metal, so the app points MLX at the prebuilt file before its first operation.
actor PictureDescriber {
    static let shared = PictureDescriber()

    private static let repo = "mlx-community/gemma-4-e2b-it-4bit"
    private static let revision = "238767527555cb75a05732a84dff5d6ba0dd6809"
    private static let files = [
        "config.json", "generation_config.json", "chat_template.jinja", "processor_config.json",
        "tokenizer.json", "tokenizer_config.json", "model.safetensors.index.json", "model.safetensors",
    ]
    /// `mlx_metal-0.32.2-py3-none-macosx_26_0_arm64.whl` on PyPI: a zip with mlx/lib/mlx.metallib.
    private static let kernelsURL = URL(string:
        "https://files.pythonhosted.org/packages/dd/cd/4e50bf325100e7165e13d025f264362bf0009196269f9eaf87f2c6e738a2/mlx_metal-0.32.2-py3-none-macosx_26_0_arm64.whl")!
    private static let kernelsSHA256 = "e6abeac9ac5265830c9c1541b6f96e9be37a85c2446763a46ad466c63a3837ab"

    private static var modelFolder: URL { ModelFiles.root.appendingPathComponent("Gemma4E2B/\(revision)", isDirectory: true) }
    private static var kernelsFolder: URL { ModelFiles.root.appendingPathComponent("MLX/0.32.2", isDirectory: true) }
    private static var kernels: URL { kernelsFolder.appendingPathComponent("mlx.metallib") }

    /// The same words the 18 Oct test was run with.
    static let prompt = """
        This picture was taken during a conversation, by the laptop camera or as a screenshot. \
        Describe it so it can be found by search later. First one or two plain sentences on what it shows: \
        the setting, people, objects, or what kind of screen and app. Then copy the most important words, \
        names and numbers you can read, in the language they are written in. No preamble, no markdown.
        """

    private var container: ModelContainer?
    private var kernelsSet = false

    /// Downloads on first use, then loads once until `release()`.
    private func prepare() async throws -> ModelContainer {
        if let container { return container }
        let fm = FileManager.default
        if !ModelFiles.isReady(Self.kernelsFolder) {
            try fm.createDirectory(at: Self.kernelsFolder, withIntermediateDirectories: true)
            let wheel = Self.kernelsFolder.appendingPathComponent("mlx_metal.whl")
            try await ModelFiles.fetch(Self.kernelsURL, to: wheel, sha256: Self.kernelsSHA256)
            let unpacked = Self.kernelsFolder.appendingPathComponent("unpacked", isDirectory: true)
            try? fm.removeItem(at: unpacked)
            try Self.unzip(wheel, into: unpacked)
            try? fm.removeItem(at: Self.kernels)
            try fm.moveItem(at: unpacked.appendingPathComponent("mlx/lib/mlx.metallib"), to: Self.kernels)
            try? fm.removeItem(at: unpacked)
            try? fm.removeItem(at: wheel)
            try ModelFiles.markReady(Self.kernelsFolder)
            Log.search.info("pictures: GPU kernels downloaded")
        }
        if !kernelsSet {
            // Before any MLX operation, or MLX looks beside the app and finds nothing.
            mlx_metal_set_metallib_path(Self.kernels.path)
            kernelsSet = true
        }
        if !ModelFiles.isReady(Self.modelFolder) {
            try await ModelFiles.fetch(repo: Self.repo, revision: Self.revision, files: Self.files, into: Self.modelFolder)
            try ModelFiles.markReady(Self.modelFolder)
            Log.search.info("pictures: Gemma 4 E2B downloaded")
        }
        let loaded = try await loadModelContainer(from: Self.modelFolder, using: TokenizerLoaderBridge())
        container = loaded
        return loaded
    }

    /// What is in the picture, as Gemma writes it: a sentence or two, then the words on it.
    func describe(_ url: URL) async throws -> String {
        let container = try await prepare()
        let session = ChatSession(
            container, generateParameters: GenerateParameters(maxTokens: 220, temperature: 0), processing: .init())
        let text = try await session.respond(to: Self.prompt, image: .url(url))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Already on this Mac: titling a Tamil recording never starts a 3.3 GB download.
    static var isDownloaded: Bool { ModelFiles.isReady(modelFolder) && ModelFiles.isReady(kernelsFolder) }

    /// Words in, words out, no picture: a Tamil recording's title (Gokul, 20 Oct 2026, 1A),
    /// since Apple's model won't read Tamil and Gemma does.
    func write(_ prompt: String, maxTokens: Int) async throws -> String {
        let container = try await prepare()
        let session = ChatSession(
            container, generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0), processing: .init())
        return try await session.respond(to: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lets go of the model (4 GB) once the pictures are read.
    func release() {
        guard container != nil else { return }
        container = nil
        MLX.GPU.clearCache()
    }

    private static func unzip(_ zip: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModelFiles.Failure.download("the GPU kernels") }
    }
}

/// swift-transformers' tokenizer in mlx-swift-lm's shape (mlx-swift-lm's own
/// `#huggingFaceTokenizerLoader` does the same, through a macro package this app avoids).
private struct TokenizerLoaderBridge: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
