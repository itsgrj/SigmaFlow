import Foundation

/// A cloud model and the credential needed to call it. Capturing this value before starting
/// detached meeting work avoids reaching into main-actor settings from that task.
struct CloudCredentials: Sendable {
    enum Provider: String, Sendable {
        case anthropic
        case openRouter

        var displayName: String {
            switch self {
            case .anthropic: "Anthropic"
            case .openRouter: "OpenRouter"
            }
        }
    }

    let provider: Provider
    let apiKey: String

    static func current(for choice: StyleEngineChoice) -> CloudCredentials? {
        switch choice {
        case .claude:
            return Keychain.anthropicKey.flatMap { $0.isEmpty ? nil : CloudCredentials(provider: .anthropic, apiKey: $0) }
        case .openRouter:
            return Keychain.openRouterKey.flatMap { $0.isEmpty ? nil : CloudCredentials(provider: .openRouter, apiKey: $0) }
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
            if code == 401 || code == 403 {
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

/// The common completion path for styles, meeting titles, and lenses. OpenRouter uses its
/// free-model router so this option never intentionally selects a paid model.
enum CloudTextClient {
    private static let anthropicModel = "claude-sonnet-4-5"
    private static let openRouterModel = "openrouter/free"

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
        }
        return try parse(data, from: credentials.provider)
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

    /// The endpoint and headers for a provider; the caller adds the body.
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
        }
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    // MARK: - Streaming

    /// The reply as it is written, a piece at a time (Autowrite shows it arriving). A
    /// JPEG goes along as a picture to Anthropic only: OpenRouter's free router may pick a
    /// model that cannot see, so it gets the words alone. `timeout` is how long the stream
    /// may go quiet, not its whole length.
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
                    var request = baseRequest(credentials, timeout: timeout)
                    request.httpBody = try streamBody(
                        system: system, user: user, jpeg: jpeg, maxTokens: maxTokens,
                        temperature: temperature, provider: credentials.provider)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 16_000 { break }
                        }
                        throw CloudTextError.http(credentials.provider, http.statusCode, errorMessage(from: data))
                    }
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
        case .openRouter:
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
        case .openRouter:
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

    private static func parse(_ data: Data, from provider: CloudCredentials.Provider) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudTextError.emptyResponse(provider)
        }
        let result: String?
        switch provider {
        case .anthropic:
            result = (json["content"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }.joined()
        case .openRouter:
            result = (json["choices"] as? [[String: Any]])?.first
                .flatMap { $0["message"] as? [String: Any] }?["content"] as? String
        }
        let cleaned = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleaned.isEmpty else { throw CloudTextError.emptyResponse(provider) }
        return cleaned
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
    }
}