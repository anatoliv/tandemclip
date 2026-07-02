import Foundation
import Security

/// Minimal login-Keychain store for the pairing secret. Generic-password items
/// under the app's service; created and read by the app itself, so no prompt.
enum KeychainStore {
    private static let service = "com.tandemclip"

    static func get(_ account: String) -> String? { getStatus(account).value }

    /// Reads the item and returns the raw OSStatus so callers can distinguish
    /// "not found" (safe to create fresh) from "access denied / locked" (must
    /// NOT overwrite — the secret is still there, just unreadable right now).
    static func getStatus(_ account: String) -> (value: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data {
            return (String(data: data, encoding: .utf8), status)
        }
        return (nil, status)
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
