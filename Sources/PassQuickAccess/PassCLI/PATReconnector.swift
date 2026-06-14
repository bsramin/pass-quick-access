// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LocalAuthentication

/// Restores a lost `pass-cli` session from the stored Personal Access Token. It
/// reads the token behind Touch ID and runs a token login, so the panel and the
/// SSH agent come back without an interactive sign-in. Reads reuse an already
/// authenticated `LAContext` when one is offered, so a Touch ID the user just did
/// for another action covers the reconnect too.
@MainActor
final class PATReconnector {
    private let client: PassCLIClient
    private let hasStoredToken: () -> Bool
    private let readToken: (LAContext) -> SensitiveString?
    private let authenticate: (String) async -> LAContext?

    /// Invoked after a reconnect succeeds, to reload the index and recover the agent.
    var onReconnected: (() async -> Void)?

    init(
        client: PassCLIClient,
        hasStoredToken: @escaping () -> Bool = PATStore.hasToken,
        readToken: @escaping (LAContext) -> SensitiveString? = { PATStore.read(using: $0) },
        authenticate: @escaping (String) async -> LAContext? = PATReconnector.biometricAuthenticate
    ) {
        self.client = client
        self.hasStoredToken = hasStoredToken
        self.readToken = readToken
        self.authenticate = authenticate
    }

    /// Authenticates the user (Touch ID, falling back to the Mac password) and hands
    /// back the context, so the Keychain read that follows can reuse it. Uses the
    /// same forgiving policy as the panel unlock, so a biometric lockout doesn't
    /// strand the user with a saved token they can't use.
    static func biometricAuthenticate(reason: String) async -> LAContext? {
        let auth = BiometricContext()
        guard auth.canEvaluate(.deviceOwnerAuthentication),
              (try? await auth.evaluate(.deviceOwnerAuthentication, reason: reason)) == true
        else {
            return nil
        }
        return auth.context
    }

    /// Whether a stored token is available to reconnect with.
    var isAvailable: Bool { hasStoredToken() }

    /// Re-establishes only the session, without the index/agent recovery callback.
    /// Used mid-signature, where restarting the agent would break the in-flight
    /// upstream connection; the still-running daemon signs over the restored
    /// session. Reuses an already-authenticated context. No-op when the session
    /// is up or no token is stored.
    @discardableResult
    func restoreSessionIfNeeded(using context: LAContext) async -> Bool {
        guard hasStoredToken() else { return false }
        if await client.hasSession() { return true }
        return await performLogin(using: context)
    }

    /// Reuses an already-authenticated context to reconnect if the session has
    /// dropped, then runs the full recovery (index reload + agent restart). Safe
    /// to call after any successful biometric outside of an active signature.
    @discardableResult
    func reconnectIfNeeded(using context: LAContext) async -> Bool {
        guard hasStoredToken() else { return false }
        if await client.hasSession() { return true }
        return await reconnectAndRecover(using: context)
    }

    /// Explicit reconnect: prompts for Touch ID, then re-logs in and recovers.
    @discardableResult
    func reconnectInteractively(reason: String) async -> Bool {
        guard let context = await authenticate(reason) else { return false }
        return await reconnectAndRecover(using: context)
    }

    /// Reads the stored token behind Touch ID and signs in, reporting any failure
    /// for display. Used by the "Sign in now" button in Settings.
    func signInFromStore(reason: String) async -> String? {
        guard let context = await authenticate(reason) else {
            return "Touch ID was cancelled or unavailable."
        }
        guard let token = readToken(context) else {
            return "Couldn't read the saved token from the Keychain."
        }
        return await signIn(with: token)
    }

    /// Signs in with a token the user just entered, skipping the Keychain read and
    /// its Touch ID since they're present and provided it directly. Used right
    /// after saving a token in Settings. Returns `nil` on success, or a message
    /// explaining the failure for display.
    func signIn(with token: SensitiveString) async -> String? {
        do {
            try await client.login(withPAT: token)
        } catch {
            return (error as? PassCLIError)?.description ?? String(describing: error)
        }
        guard await client.hasSession() else {
            return "Signed in, but the session didn't persist. This is a pass-cli integration issue, not your token."
        }
        await onReconnected?()
        return nil
    }

    private func reconnectAndRecover(using context: LAContext) async -> Bool {
        guard await performLogin(using: context) else { return false }
        await onReconnected?()
        return true
    }

    private func performLogin(using context: LAContext) async -> Bool {
        guard let token = readToken(context) else { return false }
        return await establishSession(with: token)
    }

    private func establishSession(with token: SensitiveString) async -> Bool {
        do {
            try await client.login(withPAT: token)
        } catch {
            return false
        }
        return await client.hasSession()
    }
}
