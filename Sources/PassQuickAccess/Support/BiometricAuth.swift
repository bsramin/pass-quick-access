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
        let auth = BiometricContext()
        guard auth.canEvaluate(.deviceOwnerAuthentication) else { return false }

        let timeoutTask: Task<Void, Never>? = timeout.map { limit in
            Task {
                try? await Task.sleep(for: limit)
                if !Task.isCancelled { auth.invalidate() }
            }
        }
        defer { timeoutTask?.cancel() }

        do {
            return try await auth.evaluate(.deviceOwnerAuthentication, reason: reason)
        } catch {
            return false
        }
    }
}
