// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Security

/// The key that seals the cached index.
///
/// Thirty-two random bytes, stored `WhenUnlockedThisDeviceOnly` and never
/// synchronised, so the file next to it is readable only on this Mac and only
/// while it is unlocked. It is stored the same way as the token in `PATStore`
/// and for the same reason: a biometric ACL would ask for Touch ID at launch,
/// which is exactly the wait the cache exists to remove.
///
/// Losing the key costs nothing but a cold start. A cache that cannot be opened
/// reads as no cache at all, and the index is read from `pass-cli` as before.
enum IndexCacheKeyStore {
    private static let service = "it.ramin.PassQuickAccess.index-cache"
    private static let account = "index-cache-key"
    private static let length = 32

    /// The stored key, creating one on first use. Nil when the Keychain is
    /// unavailable, which leaves the app with no cache rather than no index.
    static func key() -> Data? {
        existing() ?? create()
    }

    static func remove() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    private static func existing() -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count == length else { return nil }
        return data
    }

    private static func create() -> Data? {
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let key = Data(bytes)

        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: key,
        ] as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Two launches racing the first write: whoever lost reads the
            // winner's key rather than sealing with one nobody will find.
            return existing()
        default:
            return nil
        }
    }
}
