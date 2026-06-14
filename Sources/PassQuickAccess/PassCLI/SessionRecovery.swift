// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Watches for a `pass-cli` session to come back after the user has been sent off
/// to sign in. It polls `pass-cli test` until a session appears or a deadline
/// passes, so the panel and the SSH agent can recover without the app relaunching.
@MainActor
final class SessionRecovery {
    private let client: PassCLIClient
    private let pollInterval: Duration
    private let maxAttempts: Int
    private var task: Task<Void, Never>?

    init(client: PassCLIClient, pollInterval: Duration = .seconds(2), maxAttempts: Int = 90) {
        self.client = client
        self.pollInterval = pollInterval
        self.maxAttempts = maxAttempts
    }

    /// Polls until a session is reachable, then calls `onResult(true)`; calls
    /// `onResult(false)` if none appears within the deadline. A second call
    /// supersedes the first, so repeated sign-in attempts don't stack pollers.
    func waitForSession(onResult: @escaping (Bool) -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<maxAttempts {
                if Task.isCancelled { return }
                if await client.hasSession() {
                    // Re-check: cancellation can land while the probe is in flight,
                    // and a superseded poll must not report success.
                    if Task.isCancelled { return }
                    onResult(true)
                    return
                }
                try? await Task.sleep(for: pollInterval)
            }
            if !Task.isCancelled { onResult(false) }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
