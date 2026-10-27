import Foundation
import FoundationModels

/// Whatever actually performs a rewrite: the model built into macOS, Anthropic, or
/// OpenRouter through the user's own key.
protocol StyleRewriting: Sendable {
    func rewrite(_ text: String, style: WritingStyle) async throws -> String
}

enum StyleError: LocalizedError {
    case noSelection
    case appleModelUnavailable(String)
    case emptyResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noSelection:
            "Select some text first, then press the shortcut."
        case .appleModelUnavailable(let reason):
            reason
        case .emptyResponse:
            "The model returned nothing. Your text was left alone."
        case .timedOut:
            "That rewrite took too long, so your text was left alone."
        }
    }
}

/// Picks the engine the user chose, each time, so switching applies to the next shortcut.
enum StyleEngines {
    /// Main-actor isolated because it reads `Settings`, which is. The only caller is
    /// `SelectionRewriter`, which already runs there.
    @MainActor
    static func current() -> any StyleRewriting {
        switch Settings.shared.styleEngine {
        case .apple: AppleStyleRewriter()
        case .claude: ClaudeStyleRewriter()
        case .openRouter: OpenRouterStyleRewriter()
        }
    }
}

// MARK: - Apple, on device

/// Free, private, and weaker. Good at tidying; it will not hold a voice across a long
/// passage the way a frontier model does.
struct AppleStyleRewriter: StyleRewriting {
    func rewrite(_ text: String, style: WritingStyle) async throws -> String {
        guard SystemLanguageModel.default.availability == .available else {
            throw StyleError.appleModelUnavailable(
                FoundationModelFormatter.unavailableReason ?? "The on-device model is unavailable."
            )
        }

        let session = LanguageModelSession(instructions: style.systemPrompt)
        let response = try await session.respond(
            to: "Rewrite this text:\n\n\(text)",
            options: GenerationOptions(
                // A rewrite is a transformation, not an invention. Low, but not the near-zero
                // used for cleanup: a style legitimately rephrases.
                temperature: 0.3,
                maximumResponseTokens: 2_000
            )
        )
        let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw StyleError.emptyResponse }
        return result
    }
}

// MARK: - Claude, user's key

/// The upgrade path. The selected text goes to Anthropic, billed to the user's own account.
struct ClaudeStyleRewriter: StyleRewriting {
    func rewrite(_ text: String, style: WritingStyle) async throws -> String {
        guard let key = Keychain.anthropicKey, !key.isEmpty else {
            throw CloudTextError.missingKey(.anthropic)
        }
        return try await cloudRewrite(text, style: style, credentials: .init(provider: .anthropic, apiKey: key))
    }

    static func verify() async throws {
        guard let key = Keychain.anthropicKey, !key.isEmpty else {
            throw CloudTextError.missingKey(.anthropic)
        }
        try await CloudTextClient.verify(.init(provider: .anthropic, apiKey: key))
    }
}

// MARK: - OpenRouter, user's key

struct OpenRouterStyleRewriter: StyleRewriting {
    func rewrite(_ text: String, style: WritingStyle) async throws -> String {
        guard let key = Keychain.openRouterKey, !key.isEmpty else {
            throw CloudTextError.missingKey(.openRouter)
        }
        return try await cloudRewrite(text, style: style, credentials: .init(provider: .openRouter, apiKey: key))
    }

    static func verify() async throws {
        guard let key = Keychain.openRouterKey, !key.isEmpty else {
            throw CloudTextError.missingKey(.openRouter)
        }
        try await CloudTextClient.verify(.init(provider: .openRouter, apiKey: key))
    }
}

private func cloudRewrite(_ text: String, style: WritingStyle, credentials: CloudCredentials) async throws -> String {
    try await CloudTextClient.complete(
        system: style.systemPrompt,
        user: "Rewrite this text:\n\n\(text)",
        maxTokens: 4_000,
        temperature: 0.3,
        credentials: credentials,
        timeout: 30
    )
}
