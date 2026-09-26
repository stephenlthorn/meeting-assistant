import Foundation
import Security

/// Where API keys live: the Keychain in the app, memory in tests.
protocol SecretStore {
    func read(_ account: String) -> String?
    /// Whether a secret exists, without reading (and so decrypting) it.
    func contains(_ account: String) -> Bool
    /// Replaces any existing secret; returns false and keeps the old one on failure.
    func write(_ value: String, for account: String) -> Bool
    func delete(_ account: String)
}

/// Generic-password Keychain storage for the API keys.
struct KeychainStore: SecretStore {
    let service: String

    func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func contains(_ account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    func write(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
