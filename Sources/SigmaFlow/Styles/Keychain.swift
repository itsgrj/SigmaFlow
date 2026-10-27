import Foundation
import Security

/// Cloud API keys live in the login keychain, never in a preferences file.
///
/// A key in UserDefaults sits in a plist any process running as the user can read, and it
/// syncs into backups as plain text. The keychain is the one place macOS actually guards.
enum Keychain {
    private static let service = "com.grj.sigmaflow"
    private static let keyAccount = "anthropic-api-key"
    private static let workspaceAccount = "anthropic-workspace-id"
    private static let openRouterAccount = "openrouter-api-key"

    static var anthropicKey: String? {
        get { read(keyAccount) }
        set { store(newValue, account: keyAccount) }
    }

    /// Only needed for identity-linked keys, which the API refuses without an
    /// `anthropic-workspace-id` header. Not a secret, but it lives next to the key so the
    /// "never in a settings file" promise stays simple and true.
    static var anthropicWorkspaceID: String? {
        get { read(workspaceAccount) }
        set { store(newValue, account: workspaceAccount) }
    }

    static var openRouterKey: String? {
        get { read(openRouterAccount) }
        set { store(newValue, account: openRouterAccount) }
    }

    static var hasAnthropicKey: Bool {
        guard let key = read(keyAccount) else { return false }
        return !key.isEmpty
    }

    static var hasOpenRouterKey: Bool {
        guard let key = read(openRouterAccount) else { return false }
        return !key.isEmpty
    }

    private static func store(_ value: String?, account: String) {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            write(value.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
        } else {
            delete(account: account)
        }
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private static func write(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)

        // Update in place when it already exists; SecItemAdd would fail with a duplicate.
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
