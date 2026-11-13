import AppKit
import Foundation

/// A server on this Mac that runs the person's own model: Ollama, LM Studio, or any other
/// that speaks the OpenAI chat format (llama.cpp, Jan, MLX). It is the fourth engine for
/// custom styles and Autowrite (docs/mockups/local-model.html, picks 1B 2A 3B 4A 5A): no key,
/// no account, and the text goes to localhost and nowhere else.
struct LocalServer: Sendable, Hashable {
    enum Kind: String, Sendable {
        /// Spoken to through its own `/api/chat`, which takes the context size and turns
        /// thinking off. Its OpenAI-style endpoint runs every model at 4,096 tokens, which a
        /// full screen overflows, and Ollama then drops the start of the prompt without a word.
        case ollama
        case lmStudio
        /// Anything else answering `/v1/models` and `/v1/chat/completions`.
        case other
    }

    let kind: Kind
    let address: URL

    /// The app's name, for the chooser and the error lines.
    var name: String {
        switch kind {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .other: "Your server"
        }
    }

    /// "localhost:11434", the way the chooser shows where a model was found.
    var place: String {
        let host = address.host() ?? address.absoluteString
        return address.port.map { "\(host):\($0)" } ?? host
    }
}

/// One model a server has.
struct LocalModel: Sendable, Hashable {
    let name: String
    let server: LocalServer
}

/// Where a request goes and which model answers it.
struct LocalTarget: Sendable, Hashable {
    let server: LocalServer
    let model: String
}

enum LocalModelError: LocalizedError {
    case noModel
    case notAnswering(LocalServer)
    case missingModel(LocalTarget)

    var errorDescription: String? {
        switch self {
        case .noModel:
            "Pick your own model on the Styles page."
        case .notAnswering(let server):
            server.kind == .other
                ? "Nothing is answering at \(server.place)."
                : "\(server.name) isn’t open."
        case .missingModel(let target):
            "\(target.server.name) doesn’t have \(target.model) any more. Pick another on the Styles page."
        }
    }
}

enum LocalModels {
    static let ollama = LocalServer(kind: .ollama, address: URL(string: "http://localhost:11434")!)
    static let lmStudio = LocalServer(kind: .lmStudio, address: URL(string: "http://localhost:1234")!)

    /// Ollama's window for every SigmaFlow request. Always the same number: a request with a
    /// different one makes Ollama load the model again. 16,384 tokens hold Autowrite's local
    /// limits (`WritePrompt.Limits.ollama`) with room for the reply.
    static let ollamaContext = 16_384

    /// How long a server may take to say what it has. It is on this Mac or it isn't there.
    static let lookTimeout: TimeInterval = 1
    /// Opening Ollama or LM Studio for a request (pick 3B): how long to wait for it to answer.
    static let openWait: Duration = .seconds(20)
    static let openPoll: Duration = .milliseconds(500)

    /// The keys `Settings` stores the picked model under, read here too so an engine off the
    /// main actor can find it.
    enum Keys {
        static let kind = "localModelServer"
        static let address = "localModelAddress"
        static let model = "localModelName"
    }

    /// The model picked on the Styles page, or nil before one is.
    static var saved: LocalTarget? {
        let defaults = UserDefaults.standard
        guard let model = defaults.string(forKey: Keys.model), !model.isEmpty,
              let kind = LocalServer.Kind(rawValue: defaults.string(forKey: Keys.kind) ?? ""),
              let address = URL(string: defaults.string(forKey: Keys.address) ?? "")
        else { return nil }
        return LocalTarget(server: LocalServer(kind: kind, address: address), model: model)
    }

    // MARK: - Finding them

    /// The models a server has, in its own order, or nil when nothing answers there.
    static func models(on server: LocalServer) async -> [LocalModel]? {
        switch server.kind {
        case .ollama:
            guard let json = await get(server.address.appending(path: "api/tags")),
                  let list = json["models"] as? [[String: Any]] else { return nil }
            return list.compactMap { ($0["name"] as? String).map { LocalModel(name: $0, server: server) } }
        case .lmStudio, .other:
            guard let json = await get(server.address.appending(path: "v1/models")),
                  let list = json["data"] as? [[String: Any]] else { return nil }
            return list.compactMap { ($0["id"] as? String).map { LocalModel(name: $0, server: server) } }
                // LM Studio lists its embedding models beside the chat ones; they can't write.
                .filter { !$0.name.localizedCaseInsensitiveContains("embed") }
        }
    }

    /// What answers at an address someone typed: Ollama when its own API does, otherwise any
    /// OpenAI-style server. Nil when nothing answers.
    static func identify(_ typed: String) async -> (server: LocalServer, models: [LocalModel])? {
        guard let address = normalised(typed) else { return nil }
        let asOllama = LocalServer(kind: .ollama, address: address)
        if let models = await models(on: asOllama) { return (asOllama, models) }
        let other = LocalServer(kind: address.port == lmStudio.address.port ? .lmStudio : .other, address: address)
        if let models = await models(on: other) { return (other, models) }
        return nil
    }

    /// "localhost:8080", "http://127.0.0.1:8080/v1/" and the like, as the server's root.
    static func normalised(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/v1") { text.removeLast(3) }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    private static func get(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = lookTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Opening them

    /// The app that serves this kind, when it is on this Mac.
    static func appURL(for kind: LocalServer.Kind) -> URL? {
        let workspace = NSWorkspace.shared
        switch kind {
        case .ollama:
            return workspace.urlForApplication(withBundleIdentifier: "com.electron.ollama")
        case .lmStudio:
            if let url = workspace.urlForApplication(withBundleIdentifier: "ai.elementlabs.lmstudio") { return url }
            let fallback = URL(fileURLWithPath: "/Applications/LM Studio.app")
            return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
        case .other:
            return nil
        }
    }

    /// Opens the server's app out of the way and waits for it to answer (pick 3B). LM
    /// Studio's app does not start its server by itself, so its `lms` tool is asked to.
    @MainActor
    static func open(_ server: LocalServer) async -> Bool {
        guard let app = appURL(for: server.kind) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        if server.kind == .lmStudio { startLMStudioServer() }
        let clock = ContinuousClock()
        let deadline = clock.now + openWait
        while clock.now < deadline {
            if await models(on: server) != nil { return true }
            try? await Task.sleep(for: openPoll)
        }
        return false
    }

    private static func startLMStudioServer() {
        let tool = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lmstudio/bin/lms")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["server", "start"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Loads Ollama's model while the person is still talking to Autowrite, so the first word
    /// doesn't wait for a cold load (about 9 s for gemma4:e4b on Gokul's Mac). A chat request
    /// with no messages only loads. Same window as the real request, or it would load twice.
    static func warm(_ target: LocalTarget) {
        guard target.server.kind == .ollama else { return }
        var request = URLRequest(url: target.server.address.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": target.model,
            "messages": [],
            "options": ["num_ctx": ollamaContext],
        ])
        Task.detached { _ = try? await URLSession.shared.data(for: request) }
    }
}
