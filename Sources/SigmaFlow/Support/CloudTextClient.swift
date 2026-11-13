import Foundation

/// A model and what is needed to call it: a key for the cloud, a server and a model name for
/// the person's own model on this Mac. Capturing this value before starting detached meeting
/// work avoids reaching into main-actor settings from that task.
struct CloudCredentials: Sendable {
    enum Provider: String, Sendable {
        case anthropic
        case openRouter
        /// The person's own model on this Mac; `target` says where and which.
        case local

        var displayName: String {
            switch self {
            case .anthropic: "Anthropic"
            case .openRouter: "OpenRouter"
            case .local: "Your model"
            }
        }
    }

    let provider: Provider
    let apiKey: String
    var target: LocalTarget? = nil

    static func onThisMac(_ target: LocalTarget) -> CloudCredentials {
        CloudCredentials(provider: .local, apiKey: "", target: target)
    }

    static func current(for choice: StyleEngineChoice) -> CloudCredentials? {
        switch choice {
        case .claude:
            return Keychain.anthropicKey.flatMap { $0.isEmpty ? nil : CloudCredentials(provider: .anthropic, apiKey: $0) }
        case .openRouter:
            return Keychain.openRouterKey.flatMap { $0.isEmpty ? nil : CloudCredentials(provider: .openRouter, apiKey: $0) }
        case .local:
            return LocalModels.saved.map(CloudCredentials.onThisMac)
        case .apple:
            // Lenses have no on-device option. Preserve the old Anthropic behavior, then let
            // an OpenRouter-only user run them without changing the style engine.
            if let key = Keychain.anthropicKey, !key.isEmpty {
                return CloudCredentials(provider: .anthropic, apiKey: key)
            }
            return Keychain.openRouterKey.flatMap { $0.isEmpty ? nil : CloudCredentials(provider: .openRouter, apiKey: $0) }
        }
    }
}

enum CloudTextError: LocalizedError {
    case missingKey(CloudCredentials.Provider)
    case http(CloudCredentials.Provider, Int, String)
    case emptyResponse(CloudCredentials.Provider)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            "Add your \(provider.displayName) API key on the Styles page."
        case .http(let provider, let code, let message):
            if provider != .local && (code == 401 || code == 403) {
                "\(provider.displayName) rejected that API key. Check it on the Styles page."
            } else if provider == .anthropic && message.contains("anthropic-workspace-id") {
                "This key is linked to a workspace. Paste the workspace ID under the key on the Styles page."
            } else {
                "\(provider.displayName) returned an error (\(code)). \(message)"
            }
        case .emptyResponse(let provider):
            "\(provider.displayName) returned nothing."
        }
    }
}

/// The common completion path for styles, meeting titles, lenses and Autowrite. OpenRouter
/// uses its free-model router so this option never intentionally selects a paid model.
enum CloudTextClient {
    private static let anthropicModel = "claude-sonnet-4-5"
    private static let openRouterModel = "openrouter/free"

    /// How long a model on this Mac may stay silent. Its first request loads it into memory,
    /// which a cloud model never makes you wait for: about 9 s for gemma4:e4b, longer for a
    /// big model on a laptop.
    static let localTimeout: TimeInterval = 90

    static func complete(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double,
        credentials: CloudCredentials,
        timeout: TimeInterval
    ) async throws -> String {
        let data: Data
        switch credentials.provider {
        case .anthropic:
            data = try await sendAnthropic(
                system: system, user: user, maxTokens: maxTokens,
                temperature: temperature, credentials: credentials, timeout: timeout)
        case .openRouter:
            data = try await sendOpenRouter(
                system: system, user: user, maxTokens: maxTokens,
                temperature: temperature, credentials: credentials, timeout: timeout)
        case .local:
            guard let target = credentials.target else { throw LocalModelError.noModel }
            data = try await withLocalServer(target) { thinkOff in
                var request = localRequest(target, timeout: timeout)
                request.httpBody = try localBody(
                    target, system: system, user: user, maxTokens: maxTokens,
                    temperature: temperature, stream: false, thinkOff: thinkOff)
                return try await send(request, provider: .local)
            }
        }
        return try parse(data, from: credentials)
    }

    static func verify(_ credentials: CloudCredentials) async throws {
        _ = try await complete(
            system: "Reply with OK.", user: "Test", maxTokens: 16, temperature: 0,
            credentials: credentials, timeout: 30)
    }

    private static func sendAnthropic(
        system: String, user: String, maxTokens: Int, temperature: Double,
        credentials: CloudCredentials, timeout: TimeInterval
    ) async throws -> Data {
        var request = baseRequest(credentials, timeout: timeout)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": anthropicModel,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ])
        return try await send(request, provider: .anthropic)
    }

    private static func sendOpenRouter(
        system: String, user: String, maxTokens: Int, temperature: Double,
        credentials: CloudCredentials, timeout: TimeInterval
    ) async throws -> Data {
        var request = baseRequest(credentials, timeout: timeout)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": openRouterModel,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])
        return try await send(request, provider: .openRouter)
    }

    /// The endpoint and headers for a cloud provider; the caller adds the body.
    private static func baseRequest(_ credentials: CloudCredentials, timeout: TimeInterval) -> URLRequest {
        var request: URLRequest
        switch credentials.provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(credentials.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let workspace = Keychain.anthropicWorkspaceID, !workspace.isEmpty {
                request.setValue(workspace, forHTTPHeaderField: "anthropic-workspace-id")
            }
        case .openRouter:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "authorization")
            request.setValue("SigmaFlow", forHTTPHeaderField: "x-title")
        case .local:
            // Never reached: a local request is built by `localRequest`, which knows the server.
            request = URLRequest(url: credentials.target?.server.address ?? URL(string: "http://localhost")!)
        }
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    // MARK: - A model on this Mac

    private static func localRequest(_ target: LocalTarget, timeout: TimeInterval) -> URLRequest {
        let path = target.server.kind == .ollama ? "api/chat" : "v1/chat/completions"
        var request = URLRequest(url: target.server.address.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    /// Ollama gets its own format: the window set (`LocalModels.ollamaContext`) and thinking
    /// off, which on a thinking model is many seconds of words nobody sees. Every other server
    /// gets the OpenAI format OpenRouter uses, with the model's own name.
    private static func localBody(
        _ target: LocalTarget, system: String, user: String, maxTokens: Int, temperature: Double,
        stream: Bool, thinkOff: Bool
    ) throws -> Data {
        let messages = [["role": "system", "content": system], ["role": "user", "content": user]]
        guard target.server.kind == .ollama else {
            return try JSONSerialization.data(withJSONObject: [
                "model": target.model,
                "max_tokens": maxTokens,
                "temperature": temperature,
                "stream": stream,
                "messages": messages,
            ])
        }
        var body: [String: Any] = [
            "model": target.model,
            "stream": stream,
            "options": [
                "num_ctx": LocalModels.ollamaContext,
                "num_predict": maxTokens,
                "temperature": temperature,
            ],
            "messages": messages,
        ]
        if thinkOff { body["think"] = false }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Runs a request to a model on this Mac (pick 3B). When nothing answers and the server's
    /// app is on this Mac, it is opened and the request sent again once. A model that can't
    /// think refuses `think` in some Ollama versions; that is retried without it.
    private static func withLocalServer<T>(
        _ target: LocalTarget, _ attempt: @Sendable (_ thinkOff: Bool) async throws -> T
    ) async throws -> T {
        func once() async throws -> T {
            do {
                return try await attempt(true)
            } catch CloudTextError.http(_, 400, let message) where message.localizedCaseInsensitiveContains("think") {
                return try await attempt(false)
            } catch CloudTextError.http(_, 404, let message) where message.localizedCaseInsensitiveContains("not found") {
                throw LocalModelError.missingModel(target)
            }
        }
        do {
            return try await once()
        } catch let error as URLError where isNotAnswering(error) {
            guard LocalModels.appURL(for: target.server.kind) != nil,
                  await LocalModels.open(target.server) else {
                throw LocalModelError.notAnswering(target.server)
            }
            do {
                return try await once()
            } catch let error as URLError where isNotAnswering(error) {
                throw LocalModelError.notAnswering(target.server)
            }
        }
    }

    private static func isNotAnswering(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code)
    }

    // MARK: - Streaming

    /// The reply as it is written, a piece at a time (Autowrite shows it arriving). A
    /// JPEG goes along as a picture to Anthropic only: OpenRouter's free router may pick a
    /// model that cannot see, and a model on this Mac gets the words alone (pick 5A).
    /// `timeout` is how long the stream may go quiet, not its whole length.
    static func stream(
        system: String,
        user: String,
        jpeg: Data?,
        maxTokens: Int,
        temperature: Double,
        credentials: CloudCredentials,
        timeout: TimeInterval
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if credentials.provider == .local {
                        try await streamLocal(
                            system: system, user: user, maxTokens: maxTokens, temperature: temperature,
                            credentials: credentials, timeout: timeout, into: continuation)
                        continuation.finish()
                        return
                    }
                    var request = baseRequest(credentials, timeout: timeout)
                    request.httpBody = try streamBody(
                        system: system, user: user, jpeg: jpeg, maxTokens: maxTokens,
                        temperature: temperature, provider: credentials.provider)
                    let bytes = try await openStream(request, provider: credentials.provider)
                    // Server-sent events: one `data:` line per event, comments and blank lines between.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
                        else { continue }
                        if let error = json["error"] as? [String: Any] {
                            throw CloudTextError.http(credentials.provider, 0, error["message"] as? String ?? "")
                        }
                        if let piece = streamedText(json, from: credentials.provider), !piece.isEmpty {
                            continuation.yield(piece)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Ollama streams one JSON object a line; the other servers stream server-sent events in
    /// the OpenAI format. Either way, a `<think>` block a model writes into its answer is held
    /// back, so it is neither typed nor shown.
    private static func streamLocal(
        system: String, user: String, maxTokens: Int, temperature: Double,
        credentials: CloudCredentials, timeout: TimeInterval,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let target = credentials.target else { throw LocalModelError.noModel }
        let bytes = try await withLocalServer(target) { thinkOff in
            var request = localRequest(target, timeout: timeout)
            request.httpBody = try localBody(
                target, system: system, user: user, maxTokens: maxTokens,
                temperature: temperature, stream: true, thinkOff: thinkOff)
            return try await openStream(request, provider: .local)
        }
        var thinking = ThinkingFilter()
        for try await line in bytes.lines {
            var text = line.trimmingCharacters(in: .whitespaces)
            if target.server.kind != .ollama {
                guard text.hasPrefix("data:") else { continue }
                text = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if text == "[DONE]" { break }
            }
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            if let message = errorText(json) { throw CloudTextError.http(.local, 0, message) }
            let piece = target.server.kind == .ollama
                ? (json["message"] as? [String: Any])?["content"] as? String
                : streamedText(json, from: .openRouter)
            if let piece, let shown = thinking.take(piece), !shown.isEmpty {
                continuation.yield(shown)
            }
            if target.server.kind == .ollama, json["done"] as? Bool == true { break }
        }
        if let rest = thinking.finish(), !rest.isEmpty { continuation.yield(rest) }
    }

    /// The bytes of a 200 response, or the error a non-200 one carries.
    private static func openStream(
        _ request: URLRequest, provider: CloudCredentials.Provider
    ) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 16_000 { break }
            }
            throw CloudTextError.http(provider, http.statusCode, errorMessage(from: data))
        }
        return bytes
    }

    private static func streamBody(
        system: String, user: String, jpeg: Data?, maxTokens: Int, temperature: Double,
        provider: CloudCredentials.Provider
    ) throws -> Data {
        switch provider {
        case .anthropic:
            var content: [[String: Any]] = []
            if let jpeg {
                content.append(["type": "image", "source": [
                    "type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString(),
                ]])
            }
            content.append(["type": "text", "text": user])
            return try JSONSerialization.data(withJSONObject: [
                "model": anthropicModel,
                "max_tokens": maxTokens,
                "temperature": temperature,
                "system": system,
                "stream": true,
                "messages": [["role": "user", "content": content]],
            ])
        case .openRouter, .local:
            return try JSONSerialization.data(withJSONObject: [
                "model": openRouterModel,
                "max_tokens": maxTokens,
                "temperature": temperature,
                "stream": true,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ])
        }
    }

    private static func streamedText(_ json: [String: Any], from provider: CloudCredentials.Provider) -> String? {
        switch provider {
        case .anthropic:
            guard json["type"] as? String == "content_block_delta",
                  let delta = json["delta"] as? [String: Any] else { return nil }
            return delta["text"] as? String
        case .openRouter, .local:
            return (json["choices"] as? [[String: Any]])?.first
                .flatMap { $0["delta"] as? [String: Any] }?["content"] as? String
        }
    }

    private static func send(_ request: URLRequest, provider: CloudCredentials.Provider) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CloudTextError.http(provider, http.statusCode, errorMessage(from: data))
        }
        return data
    }

    private static func parse(_ data: Data, from credentials: CloudCredentials) throws -> String {
        let provider = credentials.provider
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudTextError.emptyResponse(provider)
        }
        let result: String?
        switch provider {
        case .anthropic:
            result = (json["content"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }.joined()
        case .openRouter:
            result = openAIMessage(json)
        case .local:
            result = (credentials.target?.server.kind == .ollama
                ? (json["message"] as? [String: Any])?["content"] as? String
                : openAIMessage(json)).map(ThinkingFilter.strip)
        }
        let cleaned = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleaned.isEmpty else { throw CloudTextError.emptyResponse(provider) }
        return cleaned
    }

    private static func openAIMessage(_ json: [String: Any]) -> String? {
        (json["choices"] as? [[String: Any]])?.first
            .flatMap { $0["message"] as? [String: Any] }?["content"] as? String
    }

    /// The message in an error body: `{"error": {"message": …}}` from the cloud and LM Studio,
    /// `{"error": "…"}` from Ollama.
    private static func errorText(_ json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] { return error["message"] as? String ?? "" }
        return json["error"] as? String
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = errorText(json) {
            return message
        }
        return String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
    }
}

/// A `<think>…</think>` block at the start of a local model's answer (Qwen and DeepSeek write
/// their reasoning into it on servers that don't take it out). Pieces are held while the
/// answer could still be one; after it closes, or once the answer clearly isn't one, they
/// pass straight through.
struct ThinkingFilter {
    private static let open = "<think>"
    private static let close = "</think>"

    private var held = ""
    private var passing = false

    /// What to show of this piece now, or nil to hold it.
    mutating func take(_ piece: String) -> String? {
        if passing { return piece }
        held += piece
        let start = held.drop { $0.isWhitespace }
        if start.hasPrefix(Self.open) {
            guard let end = held.range(of: Self.close) else { return nil }
            passing = true
            return String(held[end.upperBound...]).trimmingLeadingWhitespace
        }
        if Self.open.hasPrefix(start) { return nil }  // "<thi" could still become "<think>"
        passing = true
        return held
    }

    /// What was held when the stream ended: an answer too short to tell. An unclosed
    /// `<think>` is all thinking, so nothing.
    mutating func finish() -> String? {
        guard !passing else { return nil }
        passing = true
        return held.drop { $0.isWhitespace }.hasPrefix(Self.open) ? nil : held
    }

    static func strip(_ text: String) -> String {
        var filter = ThinkingFilter()
        return (filter.take(text) ?? "") + (filter.finish() ?? "")
    }
}

private extension String {
    var trimmingLeadingWhitespace: String { String(drop { $0.isWhitespace }) }
}
