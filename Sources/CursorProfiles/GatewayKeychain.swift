import Foundation
import Security

// MARK: - Prism endpoint: API keys in the macOS Keychain
//
// One generic-password item per provider credential, keyed by the
// credential's id. Nothing else in Prism stores these keys.

enum GatewayKeychain {
    static let service = "com.mojolayers.prism.endpoint"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or replace) the key. An empty key deletes it.
    @discardableResult
    static func set(_ key: String, for account: String) -> Bool {
        delete(account)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var query = baseQuery(account)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrLabel as String] = "Prism endpoint key"
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a key is stored, without reading it (no Keychain prompt).
    static func exists(_ account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
