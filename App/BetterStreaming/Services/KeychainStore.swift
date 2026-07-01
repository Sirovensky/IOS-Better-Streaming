import Foundation
import Security

/// Minimal Keychain wrapper for source passwords. Credentials never go to
/// UserDefaults, the library cache, logs, or filenames — only here.
enum KeychainStore {
    private static let service = "com.betterstreaming.credentials"

    /// Store (or clear) a password. Returns true on success. A dropped write means
    /// the credential won't survive relaunch, so the caller can warn/fall back to
    /// the in-memory session password instead of failing silently next launch.
    @discardableResult
    static func set(_ value: String?, account: String) -> Bool {
        delete(account: account)
        guard let value, let data = value.data(using: .utf8) else { return true }  // clearing is a success
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
