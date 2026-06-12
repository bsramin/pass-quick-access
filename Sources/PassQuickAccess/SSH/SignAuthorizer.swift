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

/// Decides whether a sign request goes through. Order: a short session cache (to
/// avoid re-prompting during one workflow), then any persisted decision for the
/// app, then a fast deny for non-interactive `BatchMode` probes, and finally the
/// Touch ID prompt.
actor SignAuthorizer {
    /// How long an approval is reused without re-prompting, keyed by app + key.
    static let sessionTTL: TimeInterval = 15

    private let store: RememberedDecisionsStore
    private let presenter: SignApprovalPresenting
    private let rememberApprovedApps: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var sessionApprovals: [String: Date] = [:]

    init(
        store: RememberedDecisionsStore,
        presenter: SignApprovalPresenting,
        rememberApprovedApps: @escaping @Sendable () -> Bool
            = { UserDefaults.standard.bool(forKey: SettingKey.sshRememberApprovedApps) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.presenter = presenter
        self.rememberApprovedApps = rememberApprovedApps
        self.now = now
    }

    func authorize(_ request: SignRequest) async -> Bool {
        // A verified peer can ride the session cache and remembered decisions; an
        // unverified one must always face the prompt, so trust can't be spoofed.
        if let identity = request.peer.identity {
            if isInSession(identity: identity, fingerprint: request.fingerprint) {
                return true
            }
            if let decision = await store.decision(identity: identity, fingerprint: request.fingerprint) {
                return decision.allow
            }
        }

        // Scripted probes (`ssh -o BatchMode=yes`) abandon the connection before a
        // human can answer, so deny rather than hang.
        if request.client.batchMode { return false }

        let approved = await presenter.present(request)
        if approved, let identity = request.peer.identity {
            noteSession(identity: identity, fingerprint: request.fingerprint)
            if rememberApprovedApps() {
                await store.remember(RememberedSignDecision(
                    identity: identity,
                    appName: request.client.name,
                    fingerprint: nil,
                    keyName: nil,
                    allow: true,
                    createdAt: now()
                ))
            }
        }
        return approved
    }

    private func sessionKey(identity: String, fingerprint: String) -> String {
        "\(identity)|\(fingerprint)"
    }

    private func isInSession(identity: String, fingerprint: String) -> Bool {
        guard let approvedAt = sessionApprovals[sessionKey(identity: identity, fingerprint: fingerprint)] else {
            return false
        }
        return now().timeIntervalSince(approvedAt) < Self.sessionTTL
    }

    private func noteSession(identity: String, fingerprint: String) {
        sessionApprovals[sessionKey(identity: identity, fingerprint: fingerprint)] = now()
    }
}
