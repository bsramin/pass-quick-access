// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A pending request to sign with a key, with everything needed to decide and to
/// describe the request to the user.
struct SignRequest: Sendable {
    let client: RequestingProgram
    let peer: VerifiedPeer
    let fingerprint: String
    /// The key's human name, if known from the agent's identity list.
    let keyName: String?
}

/// Presents the authorization prompt and returns whether the user approved.
/// Behind a protocol so the proxy uses the real Touch ID prompt while tests
/// inject a scripted answer.
protocol SignApprovalPresenting: Sendable {
    func present(_ request: SignRequest) async -> Bool
}

/// Decides whether a sign request goes through. Order: the approval window (so a
/// program that signs repeatedly isn't asked every time), then any persisted
/// decision for the app, then a fast deny for non-interactive `BatchMode`
/// probes, and finally the Touch ID prompt.
actor SignAuthorizer {
    private let store: RememberedDecisionsStore
    private let presenter: SignApprovalPresenting
    private let rememberApprovedApps: @Sendable () -> Bool
    private let window: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date
    private var approvals: [String: Date] = [:]
    /// Prompts in flight, keyed the same way as `approvals`. Without this, two
    /// `git fetch`es that start together each get their own prompt for the same
    /// app and key.
    private var pending: [String: Task<Bool, Never>] = [:]

    init(
        store: RememberedDecisionsStore,
        presenter: SignApprovalPresenting,
        rememberApprovedApps: @escaping @Sendable () -> Bool
            = { UserDefaults.standard.bool(forKey: SettingKey.sshRememberApprovedApps) },
        window: @escaping @Sendable () -> TimeInterval = { SSHApprovalWindow.current().duration },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.presenter = presenter
        self.rememberApprovedApps = rememberApprovedApps
        self.window = window
        self.now = now
    }

    func authorize(_ request: SignRequest) async -> Bool {
        let key = windowKey(for: request)

        if let key, isWithinWindow(key) { return true }
        if let identity = request.peer.identity,
           let decision = await store.decision(identity: identity, fingerprint: request.fingerprint) {
            return decision.allow
        }

        // Scripted probes (`ssh -o BatchMode=yes`) abandon the connection before a
        // human can answer, so deny rather than hang.
        if request.client.batchMode { return false }

        guard let key else { return await prompt(for: request) }
        if let existing = pending[key] { return await existing.value }
        let task = Task { await self.prompt(for: request) }
        pending[key] = task
        let approved = await task.value
        pending[key] = nil
        if approved { approvals[key] = now() }
        return approved
    }

    private func prompt(for request: SignRequest) async -> Bool {
        let approved = await presenter.present(request)
        guard approved, let identity = request.peer.identity, rememberApprovedApps() else { return approved }
        await store.remember(RememberedSignDecision(
            identity: identity,
            appName: request.client.name,
            fingerprint: request.fingerprint,
            keyName: request.keyName,
            allow: true,
            createdAt: now()
        ))
        return approved
    }

    /// What an approval is remembered against for the length of the window: the
    /// app's signing identity when we have one, otherwise the exact binary. A
    /// peer we can pin neither way is asked about every time.
    private func windowKey(for request: SignRequest) -> String? {
        if let identity = request.peer.identity { return "\(identity)|\(request.fingerprint)" }
        return request.peer.codeHash.map { "code:\($0)|\(request.fingerprint)" }
    }

    private func isWithinWindow(_ key: String) -> Bool {
        guard let approvedAt = approvals[key] else { return false }
        guard now().timeIntervalSince(approvedAt) < window() else {
            approvals[key] = nil
            return false
        }
        return true
    }
}
