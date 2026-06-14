// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LocalAuthentication
import Security

/// Keychain storage for the Proton Pass Personal Access Token used to re-establish
/// a session after it expires.
///
/// Ideally the token would be sealed behind a biometric Keychain ACL
/// (`.biometryCurrentSet`), but that requires an Apple Developer
/// `application-identifier` entitlement, which this locally-signed, not-yet-
/// notarized build doesn't have (the Keychain returns `errSecMissingEntitlement`).
/// So for now the token is stored `WhenUnlockedThisDeviceOnly`, and Touch ID is
/// enforced in code by `PATReconnector`, which authenticates before every read.
/// Reads already forward the authenticated `LAContext`, so once the app ships
/// signed with a team, re-adding the access control to `save` restores
/// Keychain-enforced biometrics with no other change.
enum PATStore {
    private static let service = "it.ramin.PassQuickAccess.pat"
    private static let account = "proton-pass-personal-access-token"

    enum StoreError: Error {
        case keychain(OSStatus)
    }

    /// Whether a token is stored. Reads only the attributes, not the value.
    static func hasToken() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Stores the token, replacing any existing one. See the type comment for why
    /// it isn't sealed behind a biometric ACL yet.
    static func save(_ token: SensitiveString) throws {
        remove()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(token.reveal().utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    /// Reads the token. The caller is expected to have authenticated first (see the
    /// type comment); the `context` is forwarded so that, once the item is sealed
    /// behind a biometric ACL, the same Touch ID is reused with no second prompt.
    static func read(using context: LAContext? = nil, reason: String? = nil) -> SensitiveString? {
        let authContext = context ?? LAContext()
        if context == nil, let reason {
            authContext.localizedReason = reason
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authContext,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return SensitiveString(token)
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
