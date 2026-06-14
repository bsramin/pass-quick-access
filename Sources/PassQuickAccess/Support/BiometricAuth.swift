// SPDX-License-Identifier: GPL-3.0-only

import LocalAuthentication

/// Touch ID with an automatic fallback to the device password, used to gate the
/// quick-access panel.
@MainActor
enum BiometricAuth {
    /// Prompts for Touch ID (with a password fallback). If `timeout` is given and
    /// the user neither approves nor cancels within it, the prompt is dismissed
    /// and the result is `false` (treated as a denial).
    static func authenticate(reason: String, timeout: Duration? = nil) async -> Bool {
        await authenticatedContext(reason: reason, timeout: timeout) != nil
    }

    /// Like `authenticate`, but returns the authenticated context on success so a
    /// caller can reuse the same Touch ID for a follow-on Keychain read. Returns
    /// `nil` on failure, cancel, or timeout.
    static func authenticatedContext(reason: String, timeout: Duration? = nil) async -> BiometricContext? {
        let auth = BiometricContext()
        guard auth.canEvaluate(.deviceOwnerAuthentication) else { return nil }

        let timeoutTask: Task<Void, Never>? = timeout.map { limit in
            Task {
                try? await Task.sleep(for: limit)
                if !Task.isCancelled { auth.invalidate() }
            }
        }
        defer { timeoutTask?.cancel() }

        do {
            return try await auth.evaluate(.deviceOwnerAuthentication, reason: reason) ? auth : nil
        } catch {
            return nil
        }
    }
}
