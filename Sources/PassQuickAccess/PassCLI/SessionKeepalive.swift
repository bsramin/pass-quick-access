// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Keeps the `pass-cli` session from going cold while the app sits in the menu
/// bar, so the next hotkey press doesn't pay for a reconnect first.
///
/// The ping is a single `vault list` and nothing more: it names the vaults and
/// reads nothing inside them. Re-reading the index would refresh the session
/// just as well, but that is one `item list` per vault and each holds the
/// cross-process session lock, so a periodic index pass would sit in front of an
/// SSH signature the user is waiting on.
@MainActor
final class SessionKeepalive {
    private let client: PassCLIClient
    private let interval: Duration
    private var task: Task<Void, Never>?

    /// Invoked when a ping finds the session gone, to restore it from the stored
    /// token. Left to the owner, which has the reconnect and the SSH agent.
    var onSessionLost: (() async -> Void)?

    init(client: PassCLIClient, interval: Duration = .seconds(15 * 60)) {
        self.client = client
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await ping()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One probe, called on wake too, where a lapse is most likely and the next
    /// tick is too late to be useful.
    func ping() async {
        if await client.hasSession() { return }
        await onSessionLost?()
    }
}
