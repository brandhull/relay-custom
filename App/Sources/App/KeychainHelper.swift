import Foundation
import Security

/// Stores strings in the Keychain with `kSecAttrSynchronizable` set, so
/// values sync across the user's devices via iCloud Keychain — no app
/// entitlement required, just relies on the user having iCloud Keychain
/// enabled in Settings. Used for API keys/tokens, which don't belong in
/// NSUbiquitousKeyValueStore.
enum KeychainHelper {
    static func set(_ value: String, key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: true
        ]
        SecItemDelete(query as CFDictionary)

        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
