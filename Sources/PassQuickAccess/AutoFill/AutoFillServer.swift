// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// What the server needs from the panel's index. Kept to four members and behind
/// a protocol so the routing can be tested against a fake instead of a live view
/// model and a real `pass-cli`.
@MainActor
protocol AutoFillIndexSource: AnyObject {
    /// False while the first pass over the vaults is still running.
    var autofillIsIndexReady: Bool { get }
    /// True once a command has found the session gone and the panel is showing
    /// the signed-out prompt.
    var autofillIsSignedOut: Bool { get }
    /// Reads the vaults if that hasn't happened yet. The extension may well be
    /// the first thing to ask for anything after a launch.
    func autofillLoadIndexIfNeeded() async
    /// Items whose stored URLs match any of these hosts, already normalised, or
    /// everything when the list is empty.
    func autofillItems(matchingHosts hosts: [String]) -> [ItemSummary]
    /// The item a record identifier names, or nil when it names nothing.
    func autofillItem(recordIdentifier: String) -> ItemSummary?
    /// Tries to bring a lapsed session back from the stored token, the same way
    /// the panel does when a command finds it gone. Returns whether it worked.
    func autofillRestoreSession() async -> Bool
}

/// Answers the credential provider over the shared container's socket.
///
/// The server never takes an item reference from the wire. A record identifier
/// is looked up in the index and the reference found there is what reaches
/// `pass-cli`, so nothing a caller sends can steer the command line, and an
/// identifier for an item that isn't in the vault is simply not found.
final class AutoFillServer: @unchecked Sendable {
    private let client: PassCLIClient
    private let index: any AutoFillIndexSource
    private let unlockWindow: UnlockWindow
    private let socketPath: String
    /// Injectable so the routing can be tested over a `socketpair`, where there
    /// is no signed peer to inspect. The default is the real check, and it is
    /// the only thing standing between a caller and the vault, so it is never
    /// weakened in a shipping path.
    private let verifyPeer: @Sendable (Int32) -> VerifiedPeer
    private var listener: AgentSocketListener?
    /// Bounds how long a connection thread waits for a request that never
    /// arrives. Generous next to a local write, tight next to a stuck peer.
    private static let requestTimeout: TimeInterval = 5

    init(
        client: PassCLIClient,
        index: any AutoFillIndexSource,
        unlockWindow: UnlockWindow,
        socketPath: String,
        verifyPeer: @escaping @Sendable (Int32) -> VerifiedPeer = { CodeSignatureCheck.verify(fd: $0) }
    ) {
        self.client = client
        self.index = index
        self.unlockWindow = unlockWindow
        self.socketPath = socketPath
        self.verifyPeer = verifyPeer
    }

    func start() throws {
        let listener = AgentSocketListener(path: socketPath) { [weak self] fd in self?.serve(fd) }
        try listener.start()
        self.listener = listener
    }

    func stop() {
        listener?.stop()
        listener = nil
    }

    // MARK: - One connection

    /// Serves one connection to completion. Internal so a test can drive it over
    /// a socket pair rather than a listener.
    func serve(_ fd: Int32) {
        defer { close(fd) }
        UnixSocket.setReadTimeout(Self.requestTimeout, on: fd)

        // Establish the caller before reading a byte of what it wants. Anything
        // that isn't this build's own extension gets a refusal and nothing else,
        // and an unverifiable peer fails closed because CodeSignatureCheck
        // reports no identity rather than guessing.
        let peer = verifyPeer(fd)
        guard let expected = AutoFillChannel.expectedExtensionIdentity,
              peer.identity == expected else {
            respond(.failure(.denied), to: fd)
            return
        }

        // A caller that connects and says nothing, or sends a frame that doesn't
        // decode, gets silence and a closed socket. There is nothing useful to
        // tell something that isn't speaking the protocol.
        guard let request = try? AutoFillWire.read(
            AutoFillWire.Request.self, from: fd, limit: AutoFillWire.maxRequestLength
        ).flatMap({ $0 }) else { return }

        guard request.version == AutoFillWire.version else {
            respond(.failure(.unsupportedVersion), to: fd)
            return
        }

        respond(handle(request), to: fd)
    }

    private func respond(_ body: AutoFillWire.Response.Body, to fd: Int32) {
        guard let frame = try? AutoFillWire.frame(AutoFillWire.Response(body)) else { return }
        _ = UnixSocket.writeAll(frame, to: fd)
    }

    private func handle(_ request: AutoFillWire.Request) -> AutoFillWire.Response.Body {
        switch request.body {
        case .status:
            // Through the same resolution as the rest: a status that reports a
            // lapsed session nobody tried to repair would be a different answer
            // from every other request, for no reason a caller could guess.
            return .status(waitFor { await self.resolved(request) })
        case let .matches(services, kind):
            return waitFor { await self.matches(services: services, kind: kind, request: request) }
        case let .password(recordIdentifier):
            return waitFor {
                await self.secret(recordIdentifier: recordIdentifier, request: request) { reference in
                    try await self.client.password(for: reference)
                }
            }
        case let .oneTimeCode(recordIdentifier):
            return waitFor {
                await self.secret(recordIdentifier: recordIdentifier, request: request) { reference in
                    try await self.client.totp(for: reference)
                }
            }
        }
    }

    // MARK: - The answers

    @MainActor
    private func state(authenticated: Bool) -> AutoFillWire.Response.State {
        if authenticated {
            // A Touch ID the extension has just completed answers the lock for
            // this request whatever the window says. It matters most under
            // "authenticate every time", where the window never opens at all
            // and consulting it would refuse a user who has just proved who
            // they are. Recording it also extends the window when the setting
            // is a timeout, so the panel doesn't ask again a moment later.
            unlockWindow.record()
        } else if unlockWindow.isRequired {
            return .locked
        }
        if index.autofillIsSignedOut { return .signedOut }
        return index.autofillIsIndexReady ? .ready : .indexing
    }

    @MainActor
    private func matches(
        services: [String],
        kind: AutoFillWire.Request.Kind,
        request: AutoFillWire.Request
    ) async -> AutoFillWire.Response.Body {
        switch await resolved(request) {
        case .locked: return .failure(.locked)
        case .signedOut: return .failure(.signedOut)
        case .indexing:
            // Start the read, but answer now. Reading every vault is one
            // pass-cli run per vault and can outlast any deadline worth giving
            // a socket, so holding the connection open turns a slow first load
            // into a severed one. The extension polls while it shows a spinner.
            // loadIfNeeded is a no-op while a pass is already running, so a
            // caller that asks repeatedly does not stack them.
            Task { await index.autofillLoadIndexIfNeeded() }
            return .failure(.indexNotReady)
        case .ready:
            break
        }

        // A service identifier is a bare domain or a full URL depending on who
        // is asking; WebHost copes with both and drops a leading "www.".
        let hosts = services.compactMap(WebHost.from)
        let matched = index.autofillItems(matchingHosts: hosts)
        let matchedIDs = Set(matched.map(\.id))
        // Everything else follows the matches rather than being withheld. Host
        // matching is a good guess and no more: plenty of Google logins are
        // saved against gmail.com, and an item with no URL at all matches
        // nothing by construction while still being the one the user wants.
        let rest = hosts.isEmpty
            ? []
            : index.autofillItems(matchingHosts: []).filter { !matchedIDs.contains($0.id) }
        let usable: (ItemSummary) -> Bool = kind == .oneTimeCode
            ? { $0.hasTOTP }
            : { $0.hasPassword }
        return .matches(
            matched.filter(usable).map { Self.candidate($0, matchesSite: true) }
                + rest.filter(usable).map { Self.candidate($0, matchesSite: false) }
        )
    }

    @MainActor
    private func secret(
        recordIdentifier: String,
        request: AutoFillWire.Request,
        read: @escaping (ItemReference) async throws -> SensitiveString
    ) async -> AutoFillWire.Response.Body {
        switch await resolved(request) {
        case .locked: return .failure(.locked)
        case .signedOut: return .failure(.signedOut)
        case .indexing, .ready: break
        }

        guard let item = index.autofillItem(recordIdentifier: recordIdentifier) else {
            return .failure(.notFound)
        }
        do {
            return .secret(try await read(item.reference).reveal())
        } catch let error as PassCLIError where error.isServiceUnreachable {
            return .failure(.timedOut)
        } catch let error as PassCLIError where error.isAuthenticationFailure {
            // The session went while we were using it, which a long idle makes
            // ordinary. Bring it back and read again rather than asking the
            // user to go and do it: they are mid-login, and the panel heals the
            // same lapse without involving them either.
            guard await index.autofillRestoreSession() else { return .failure(.signedOut) }
            guard let value = try? await read(item.reference) else { return .failure(.signedOut) }
            return .secret(value.reveal())
        } catch {
            return .failure(.notFound)
        }
    }

    /// The state to act on, having first tried to heal a lapsed session. The
    /// panel restores one from the stored token without a prompt, and there is
    /// no reason a fill should be told to go and do by hand what a copy repairs
    /// on its own.
    @MainActor
    private func resolved(_ request: AutoFillWire.Request) async -> AutoFillWire.Response.State {
        let current = state(authenticated: request.authenticated)
        guard current == .signedOut else { return current }
        guard await index.autofillRestoreSession() else { return .signedOut }
        return state(authenticated: request.authenticated)
    }

    private static func candidate(
        _ item: ItemSummary,
        matchesSite: Bool
    ) -> AutoFillWire.Response.Candidate {
        AutoFillWire.Response.Candidate(
            recordIdentifier: item.id,
            title: item.title,
            account: item.account,
            vaultName: item.vaultName,
            hasOneTimeCode: item.hasTOTP,
            matchesSite: matchesSite
        )
    }

    /// Bridges an async, main-actor answer back to this connection's thread.
    /// Safe because the thread serves one connection and is never the main one,
    /// so blocking it stalls this caller and nothing else. The same shape the
    /// SSH relay uses, and for the same reason.
    private func waitFor<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AutoFillResultBox<T>()
        Task {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }
}

/// Written once before the waiting thread is signalled, then read. No concurrent
/// access, which is what the unchecked conformance is asserting.
private final class AutoFillResultBox<T>: @unchecked Sendable {
    var value: T?
}
