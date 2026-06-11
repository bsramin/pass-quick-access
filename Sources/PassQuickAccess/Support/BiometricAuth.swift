// SPDX-License-Identifier: GPL-3.0-only

import LocalAuthentication

/// Touch ID with an automatic fallback to the device password, used to gate the
/// quick-access panel.
@MainActor
enum BiometricAuth {
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
