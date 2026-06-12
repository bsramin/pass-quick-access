// SPDX-License-Identifier: GPL-3.0-only

import LocalAuthentication

/// Wraps an `LAContext` so it can be shared between the embedded sensor view, the
/// async evaluation, and a cancelling timer. `LAContext` isn't `Sendable`, but it
/// is documented as safe to invalidate from another thread while evaluating, which
/// is the only concurrent use here, so the unchecked conformance holds.
final class BiometricContext: @unchecked Sendable {
    let context = LAContext()

    func canEvaluate(_ policy: LAPolicy) -> Bool {
        context.canEvaluatePolicy(policy, error: nil)
    }

    func evaluate(_ policy: LAPolicy, reason: String) async throws -> Bool {
        try await context.evaluatePolicy(policy, localizedReason: reason)
    }

    func invalidate() {
        context.invalidate()
    }
}
