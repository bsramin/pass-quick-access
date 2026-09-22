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
    /// Items whose stored URLs match any of these hosts, or everything when the
    /// list is empty.
    func autofillItems(matchingHosts hosts: [String]) -> [ItemSummary]
    /// The item a record identifier names, or nil when it names nothing.
    func autofillItem(recordIdentifier: String) -> ItemSummary?
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
    private var listener: AgentSocketListener?
    /// Bounds how long a connection thread waits for a request that never
    /// arrives. Generous next to a local write, tight next to a stuck peer.
    private static let requestTimeout: TimeInterval = 5

    init(
        client: PassCLIClient,
        index: any AutoFillIndexSource,
        unlockWindow: UnlockWindow,
        socketPath: String
    ) {
        self.client = client
        self.index = index
        self.unlockWindow = unlockWindow
        self.socketPath = socketPath
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

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        UnixSocket.setReadTimeout(Self.requestTimeout, on: fd)

        // Establish the caller before reading a byte of what it wants. Anything
        // that isn't this build's own extension gets a refusal and nothing else,
        // and an unverifiable peer fails closed because CodeSignatureCheck
        // reports no identity rather than guessing.
        let peer = CodeSignatureCheck.verify(fd: fd)
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
            return .status(waitFor { await self.state(authenticated: request.authenticated) })
        case let .matches(hosts, kind):
            return waitFor { await self.matches(hosts: hosts, kind: kind, request: request) }
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
        if authenticated { unlockWindow.record() }
        if unlockWindow.isRequired { return .locked }
        if index.autofillIsSignedOut { return .signedOut }
        return index.autofillIsIndexReady ? .ready : .indexing
    }

    @MainActor
    private func matches(
        hosts: [String],
        kind: AutoFillWire.Request.Kind,
        request: AutoFillWire.Request
    ) async -> AutoFillWire.Response.Body {
        switch state(authenticated: request.authenticated) {
        case .locked: return .failure(.locked)
        case .signedOut: return .failure(.signedOut)
        case .indexing:
            // First thing to ask after a launch is quite likely to be this, so
            // read the vaults rather than reporting an empty list.
            await index.autofillLoadIndexIfNeeded()
            guard index.autofillIsIndexReady else { return .failure(.indexNotReady) }
        case .ready:
            break
        }

        let items = index.autofillItems(matchingHosts: hosts)
        let wanted = kind == .oneTimeCode ? items.filter(\.hasTOTP) : items.filter(\.hasPassword)
        return .matches(wanted.map(Self.candidate))
    }

    @MainActor
    private func secret(
        recordIdentifier: String,
        request: AutoFillWire.Request,
        read: @escaping (ItemReference) async throws -> SensitiveString
    ) async -> AutoFillWire.Response.Body {
        switch state(authenticated: request.authenticated) {
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
            return .failure(.signedOut)
        } catch {
            return .failure(.notFound)
        }
    }

    private static func candidate(_ item: ItemSummary) -> AutoFillWire.Response.Candidate {
        AutoFillWire.Response.Candidate(
            recordIdentifier: item.id,
            title: item.title,
            account: item.account,
            vaultName: item.vaultName,
            hasOneTimeCode: item.hasTOTP
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
