import Foundation

/// One remote MCP server, spoken to over Streamable HTTP: JSON-RPC posted to the server's one
/// URL, answered either as plain JSON or as a short server-sent-event stream. Only the client
/// half SigmaFlow needs: start a session, list the tools, call one.
///
/// The URL is a secret: Zoho MCP puts the API key in its path. It lives in the Keychain and is
/// never logged or shown in an error.
actor MCPClient {
    enum Failure: LocalizedError {
        case http(Int)
        case rpc(String)
        case tool(String)
        case noAnswer

        var errorDescription: String? {
            switch self {
            case .http(let code):
                code == 401 || code == 403 || code == 404
                    ? "The MCP server refused the connection (\(code)). Check the server URL."
                    : "The MCP server returned an error (\(code))."
            case .rpc(let message): "The MCP server said: \(message)"
            case .tool(let message): message
            case .noAnswer: "The MCP server didn't answer."
            }
        }
    }

    private static let protocolVersion = "2025-06-18"

    private let url: URL
    private let timeout: TimeInterval
    private let signIn: MCPSignIn
    private let mayOpenSignIn: Bool
    private var session: String?
    private var negotiatedVersion: String?
    private var started = false
    private var nextID = 0
    private var tools: [String]?

    /// `mayOpenSignIn` lets a refused request open the server's sign-in page in the browser;
    /// without it a missing sign-in is an error, so nothing pops up in the middle of writing.
    /// `scopes` picks what to ask for from the scopes the server offers.
    init(url: URL, mayOpenSignIn: Bool, scopes: @escaping @Sendable (String) -> Bool, timeout: TimeInterval = 20) {
        self.url = url
        self.timeout = timeout
        self.mayOpenSignIn = mayOpenSignIn
        signIn = MCPSignIn(server: url, scopeFilter: scopes)
    }

    /// The names of the server's tools, asked for once per client.
    func toolNames() async throws -> [String] {
        if let tools { return tools }
        try await start()
        let result = try await request("tools/list", [:])
        let names = (result["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        tools = names
        return names
    }

    /// The text a tool answers with, its text pieces joined. A tool that reports an error
    /// throws, with its own words.
    func call(_ tool: String, _ arguments: [String: any Sendable]) async throws -> String {
        try await start()
        let result = try await request("tools/call", ["name": tool, "arguments": arguments])
        let text = (result["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        if result["isError"] as? Bool == true { throw Failure.tool(text) }
        return text
    }

    private func start() async throws {
        guard !started else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let result = try await request("initialize", [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: String](),
            "clientInfo": ["name": "SigmaFlow", "version": version],
        ])
        negotiatedVersion = result["protocolVersion"] as? String
        try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], expecting: nil)
        started = true
    }

    private func request(_ method: String, _ params: [String: any Sendable]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let message = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params], expecting: id)
        if let error = message?["error"] as? [String: Any] {
            throw Failure.rpc(error["message"] as? String ?? "unknown error")
        }
        guard let result = message?["result"] as? [String: Any] else { throw Failure.noAnswer }
        return result
    }

    /// Posts one message. With an `id`, waits for the response that carries it, whether it
    /// comes back as JSON or inside an event stream; a notification expects nothing.
    /// A refused token (401) is renewed, or signed in again, once, and the message sent again.
    @discardableResult
    private func post(_ body: [String: any Sendable], expecting id: Int?) async throws -> [String: Any]? {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var token = await signIn.currentToken()
        var renewed = false
        while true {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "accept")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
            if let session { request.setValue(session, forHTTPHeaderField: "mcp-session-id") }
            if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "mcp-protocol-version") }
            request.httpBody = payload

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.noAnswer }
            if http.statusCode == 401, !renewed {
                renewed = true
                token = try await signIn.renew(
                    challenge: http.value(forHTTPHeaderField: "www-authenticate"), interactive: mayOpenSignIn)
                continue
            }
            return try await answer(bytes, http, expecting: id)
        }
    }

    private func answer(_ bytes: URLSession.AsyncBytes, _ http: HTTPURLResponse, expecting id: Int?) async throws -> [String: Any]? {
        if let given = http.value(forHTTPHeaderField: "mcp-session-id") { session = given }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        guard let id else { return nil }

        if http.value(forHTTPHeaderField: "content-type")?.contains("text/event-stream") == true {
            // One `data:` line per event, or several joined; the stream may carry
            // notifications before the response, and may stay open after it. `lines` drops
            // the blank line between events, so any other line starts a new one too.
            var event = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { event = ""; continue }
                let piece = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let message = Self.message(piece, id: id) { return message }
                event += piece
                if let message = Self.message(event, id: id) { return message }
            }
            throw Failure.noAnswer
        }
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.noAnswer }
        return message
    }

    private static func message(_ text: String, id: Int) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              (json["id"] as? Int) == id
        else { return nil }
        return json
    }
}
