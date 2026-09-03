import Foundation
import Security

/// Tokens live in the App Group keychain so the widget extension can pull
/// data on its own. Reads don't pin an access group, so items saved before
/// sharing (in the app's private group) are still found; the next save
/// moves them into the shared group.
enum Keychain {
    private static let service = "ca.thedailygain.biomarkers"
    private static let sharedGroup = "group.ca.thedailygain.biomarkers"

    static func save(_ data: Data, key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attrs[kSecAttrAccessGroup as String] = sharedGroup
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            // Shared group unavailable (e.g. entitlement missing) — keep the
            // credential in the private keychain rather than losing it.
            attrs.removeValue(forKey: kSecAttrAccessGroup as String)
            SecItemAdd(attrs as CFDictionary, nil)
        }
    }

    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data else { return nil }
        // Migrate a pre-sharing item into the App Group so the widget sees it.
        if (item[kSecAttrAccessGroup as String] as? String) != sharedGroup { save(data, key: key) }
        return data
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
