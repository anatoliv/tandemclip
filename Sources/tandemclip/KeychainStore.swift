import Foundation
import Security

/// Minimal login-Keychain store for the pairing secret. Generic-password items
/// under the app's service; created and read by the app itself, so no prompt.
enum KeychainStore {
    private static let service = "com.tandemclip"

    static func get(_ account: String) -> String? { getStatus(account).value }
    static func getData(_ account: String) -> Data? { getDataStatus(account).value }

    /// Reads the item and returns the raw OSStatus so callers can distinguish
    /// "not found" (safe to create fresh) from "access denied / locked" (must
    /// NOT overwrite — the secret is still there, just unreadable right now).
    static func getStatus(_ account: String) -> (value: String?, status: OSStatus) {
        let result = getDataStatus(account)
        if let data = result.value {
            return (String(data: data, encoding: .utf8), result.status)
        }
        return (nil, result.status)
    }

    static func getDataStatus(_ account: String) -> (value: Data?, status: OSStatus) {
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
            return (data, status)
        }
        return (nil, status)
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        setData(account, Data(value.utf8))
    }

    @discardableResult
    static func setData(_ account: String, _ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // `…ThisDeviceOnly` keeps the pairing secret and signing key off backups
        // and out of any Keychain sync — a shared secret should never leave the
        // machine that way. Set it on both update (migrates existing items) and
        // add.
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
