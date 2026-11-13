import AppKit
import CryptoKit
import Network

/// Signing in to an MCP server that asks for it, as the MCP spec lays out: OAuth 2.1 with
/// PKCE, the client registering itself, the browser for the sign-in page and a one-shot
/// listener on this Mac's loopback address for the answer. Zoho MCP works this way on every
/// data centre (5 Nov 2026: its server URL alone answers 401), so nothing here is Zoho's.
///
/// What it keeps, the registration and the tokens, sits in the Keychain as one item per
/// server host. A refresh token renews the access quietly; the browser opens only when there
/// is nothing left to renew with, and only for a client allowed to ask.
actor MCPSignIn {
    enum Failure: LocalizedError {
        case needsSignIn
        case notOffered(String)
        case refused(String)
        case timedOut
        case portBusy

        var errorDescription: String? {
            switch self {
            case .needsSignIn: "Sign in to your MCP server again."
            case .notOffered(let what): "The MCP server doesn't offer \(what)."
            case .refused(let reason): "Sign-in didn't finish: \(reason)"
            case .timedOut: "Sign-in timed out. Try again."
            case .portBusy: "Another app is using the port sign-in needs. Try again in a moment."
            }
        }
    }

    /// What is kept for one server.
    private struct Saved: Codable {
        var clientID: String
        var clientSecret: String?
        var redirectURI: String
        var tokenEndpoint: String
        var resource: String
        var accessToken: String?
        var refreshToken: String?
        var expiry: Date?
        var issued: Date?
    }

    /// Fixed, because the redirect is registered with the server and must match exactly.
    private static let loopbackPort: UInt16 = 47821
    private static let redirectURI = "http://127.0.0.1:47821/callback"
    private static let signInWait: Duration = .seconds(300)

    private let server: URL
    private let scopeFilter: @Sendable (String) -> Bool
    private var saved: Saved?

    /// `scopeFilter` picks the scopes to ask for from those the server offers, so SigmaFlow
    /// asks only for what it reads.
    init(server: URL, scopeFilter: @escaping @Sendable (String) -> Bool) {
        self.server = server
        self.scopeFilter = scopeFilter
        saved = Keychain.mcpSignIn(for: server.host() ?? "").flatMap { try? JSONDecoder().decode(Saved.self, from: Data($0.utf8)) }
    }

    /// The access token to send, renewed first if it has run out; nil before the first sign-in.
    func currentToken() async -> String? {
        guard let saved, let token = saved.accessToken else { return nil }
        if let expiry = saved.expiry, expiry < Date().addingTimeInterval(60) {
            return try? await refresh()
        }
        return token
    }

    /// After the server refused a token (or there was none): renew with the refresh token, or,
    /// when that can't help and `interactive` allows, sign in again in the browser.
    func renew(challenge: String?, interactive: Bool) async throws -> String {
        // A token issued moments ago that is already refused won't be helped by another.
        let fresh = saved?.issued.map { Date().timeIntervalSince($0) < 30 } ?? false
        if !fresh, saved?.refreshToken != nil, let token = try? await refresh() { return token }
        guard interactive else { throw Failure.needsSignIn }
        return try await signIn(challenge: challenge)
    }

    // MARK: - Signing in

    private func signIn(challenge: String?) async throws -> String {
        // Where to sign in: the challenge names the server's resource metadata, which names
        // the authorization server, whose own metadata has the endpoints.
        let origin = "\(server.scheme ?? "https")://\(server.host() ?? "")"
        let metadataURL = challenge?.firstMatch(of: /resource_metadata="([^"]+)"/).map { String($0.1) }
            ?? "\(origin)/.well-known/oauth-protected-resource"
        let resourceInfo = try await getJSON(metadataURL)
        let resource = resourceInfo["resource"] as? String ?? server.absoluteString
        let issuer = (resourceInfo["authorization_servers"] as? [String])?.first ?? origin
        let authInfo = try await getJSON("\(issuer)/.well-known/oauth-authorization-server")
        guard let authorize = authInfo["authorization_endpoint"] as? String,
              let tokenEndpoint = authInfo["token_endpoint"] as? String
        else { throw Failure.notOffered("a sign-in page") }
        let offered = (authInfo["scopes_supported"] as? [String]) ?? (resourceInfo["scopes_supported"] as? [String]) ?? []
        let scopes = offered.filter(scopeFilter)

        // Register once per server, again if the redirect ever changes.
        var client = saved
        if client == nil || client?.redirectURI != Self.redirectURI || client?.tokenEndpoint != tokenEndpoint {
            guard let register = authInfo["registration_endpoint"] as? String else { throw Failure.notOffered("registering apps") }
            var body: [String: Any] = [
                "client_name": "SigmaFlow",
                "redirect_uris": [Self.redirectURI],
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
            ]
            if !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
            let registered = try await postJSON(register, body)
            guard let id = registered["client_id"] as? String else { throw Failure.refused(Self.message(registered) ?? "the server didn't register SigmaFlow") }
            client = Saved(
                clientID: id, clientSecret: registered["client_secret"] as? String, redirectURI: Self.redirectURI,
                tokenEndpoint: tokenEndpoint, resource: resource)
        }
        guard var client else { throw Failure.needsSignIn }
        client.resource = resource

        // PKCE: the browser carries only the challenge; the verifier stays here.
        let verifier = Self.randomString(64)
        let codeChallenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(32)
        var page = URLComponents(string: authorize)
        let existing = page?.queryItems ?? []
        page?.queryItems = existing + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource),
        ] + (scopes.isEmpty ? [] : [URLQueryItem(name: "scope", value: scopes.joined(separator: " "))])
        guard let pageURL = page?.url else { throw Failure.notOffered("a usable sign-in page") }

        let code = try await Self.waitForCode(state: state) {
            Task { @MainActor in NSWorkspace.shared.open(pageURL) }
        }

        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": client.clientID,
            "code_verifier": verifier,
            "resource": resource,
        ]
        if let secret = client.clientSecret { form["client_secret"] = secret }
        let answer = try await postForm(client.tokenEndpoint, form)
        try takeTokens(from: answer, into: &client)
        return client.accessToken ?? ""
    }

    private func refresh() async throws -> String {
        guard var client = saved, let refreshToken = client.refreshToken else { throw Failure.needsSignIn }
        var form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": client.clientID,
            "resource": client.resource,
        ]
        if let secret = client.clientSecret { form["client_secret"] = secret }
        let answer = try await postForm(client.tokenEndpoint, form)
        try takeTokens(from: answer, into: &client)
        return client.accessToken ?? ""
    }

    /// Keeps a token answer. A refresh answer may leave out the refresh token; the old one stays.
    private func takeTokens(from answer: [String: Any], into client: inout Saved) throws {
        guard let access = answer["access_token"] as? String else {
            throw Failure.refused(Self.message(answer) ?? "no token came back")
        }
        client.accessToken = access
        if let renewed = answer["refresh_token"] as? String { client.refreshToken = renewed }
        let seconds = (answer["expires_in"] as? Double) ?? (answer["expires_in"] as? String).flatMap(Double.init)
        client.expiry = seconds.map { Date().addingTimeInterval($0) }
        client.issued = Date()
        saved = client
        let encoded = try JSONEncoder().encode(client)
        Keychain.setMCPSignIn(String(decoding: encoded, as: UTF8.self), for: server.host() ?? "")
    }

    // MARK: - The browser's answer

    /// Listens on the loopback address for the one request the sign-in page sends back,
    /// answers it with a line the person can read, and returns the code. `opened` runs once
    /// the listener is up.
    private static func waitForCode(state: String, opened: @escaping @Sendable () -> Void) async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: loopbackPort)!)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw Failure.portBusy }
        let once = Once()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                once.set(continuation)
                listener.stateUpdateHandler = { listenerState in
                    switch listenerState {
                    case .ready: opened()
                    case .failed: once.finish(.failure(Failure.portBusy)); listener.cancel()
                    default: break
                    }
                }
                listener.newConnectionHandler = { connection in
                    connection.start(queue: .global())
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                        let request = String(decoding: data ?? Data(), as: UTF8.self)
                        let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                        let items = URLComponents(string: "http://127.0.0.1\(target)")
                        let query = Dictionary((items?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                        guard items?.path == "/callback" else {
                            respond(connection, status: "404 Not Found", text: "")
                            return
                        }
                        if let code = query["code"], query["state"] == state {
                            respond(connection, status: "200 OK", text: "SigmaFlow is connected. You can close this tab.")
                            once.finish(.success(code))
                        } else {
                            let reason = query["error_description"] ?? query["error"] ?? "the answer didn't match this sign-in"
                            respond(connection, status: "200 OK", text: "SigmaFlow couldn't sign in: \(reason)")
                            once.finish(.failure(Failure.refused(reason)))
                        }
                        listener.cancel()
                    }
                }
                listener.start(queue: .global())
                Task {
                    try? await Task.sleep(for: signInWait)
                    once.finish(.failure(Failure.timedOut))
                    listener.cancel()
                }
            }
        } onCancel: {
            once.finish(.failure(CancellationError()))
            listener.cancel()
        }
    }

    private static func respond(_ connection: NWConnection, status: String, text: String) {
        let page = """
        <!doctype html><meta charset="utf-8"><title>SigmaFlow</title>\
        <body style="font: 16px -apple-system, sans-serif; margin: 64px">\(text)</body>
        """
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Resumes a continuation exactly once, whichever of answer, failure, timeout or
    /// cancellation comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var pending: Result<String, Error>?

        func set(_ continuation: CheckedContinuation<String, Error>) {
            lock.lock(); defer { lock.unlock() }
            if let pending { continuation.resume(with: pending); self.pending = nil } else { self.continuation = continuation }
        }

        func finish(_ result: Result<String, Error>) {
            lock.lock(); defer { lock.unlock() }
            if let continuation { continuation.resume(with: result); self.continuation = nil }
            else if pending == nil { pending = result }
        }
    }

    // MARK: - HTTP

    private func getJSON(_ url: String) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw Failure.notOffered("a readable address") }
        let (data, _) = try await URLSession.shared.data(from: target)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func postJSON(_ url: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw Failure.notOffered("a readable address") }
        var request = URLRequest(url: target, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func postForm(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw Failure.notOffered("a readable address") }
        var request = URLRequest(url: target, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/:")
        request.httpBody = Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func message(_ answer: [String: Any]) -> String? {
        (answer["error_description"] as? String) ?? (answer["error"] as? String) ?? (answer["message"] as? String)
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in characters.randomElement()! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
