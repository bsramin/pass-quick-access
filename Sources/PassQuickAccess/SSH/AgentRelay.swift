// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Handles one client connection: it relays the SSH agent protocol to the
/// upstream `pass-cli` agent, message for message, but interposes on a
/// `signRequest` to require approval, and snoops `identitiesAnswer` to learn key
/// names. The agent protocol is strictly request/response on a connection, so the
/// relay is a simple lockstep loop rather than a bidirectional pump.
struct AgentRelay: Sendable {
    let upstreamPath: String
    let authorizer: SignAuthorizer
    let keyNameCache: KeyLabelCache
    let identifier: ProcessInspector
    /// Called when the upstream agent can't be reached or rejects a signature we
    /// approved, signalling that its `pass-cli` session has gone stale. The owner
    /// uses it to restart the daemon so the next attempt succeeds.
    var onUpstreamFailure: @Sendable () -> Void = {}
    /// Restarts the upstream daemon and waits for it, returning whether it came
    /// back. Called when a new connection finds the upstream gone (often a daemon
    /// that didn't survive a long idle or a sleep/wake), so this first connection
    /// heals in place and succeeds instead of failing and forcing a manual toggle.
    /// The owner coalesces concurrent callers onto one restart.
    var healUpstream: @Sendable () async -> Bool = { false }

    /// How long to wait for an upstream reply before treating the connection as
    /// wedged. A daemon that accepts the socket but never answers must not pin this
    /// connection's thread forever; the stalled read fails and heals instead.
    static let upstreamReadTimeout: TimeInterval = 20

    /// Requests that add, remove, lock or unlock keys. This proxy is read and
    /// sign only, so it refuses them instead of letting a client reshape the agent.
    private static let blockedManagementTypes: Set<UInt8> = [17, 18, 19, 20, 21, 22, 23, 25, 26]

    /// Runs the relay loop for an accepted client fd until either side closes.
    /// Takes ownership of `clientFD` and closes it (and the upstream fd) on exit.
    func handle(clientFD: Int32) {
        defer { close(clientFD) }

        guard let upstreamFD = openUpstream(for: clientFD) else { return }
        defer { close(upstreamFD) }

        // Captured once per connection: the peer can't change behind a fd.
        let client = identifyClient(fd: clientFD)
        let peer = CodeSignatureCheck.verify(fd: clientFD)

        while true {
            let message: AgentMessage?
            do {
                message = try AgentMessage.read(from: clientFD)
            } catch {
                return
            }
            guard let message else { return }

            let reply: AgentMessage?
            switch message.type {
            case .signRequest:
                reply = handleSignRequest(message, client: client, peer: peer, upstreamFD: upstreamFD)
            case .requestIdentities:
                let answer = forward(message, to: upstreamFD)
                // A dropped reply to a plain list request means the upstream is
                // wedged or gone; heal it so the next connection reconnects.
                if answer == nil { onUpstreamFailure() }
                reply = answer.map(snoopIdentities)
            case .extensionRequest where message.extensionType == "session-bind@openssh.com":
                // pass-cli's agent breaks on this OpenSSH extension, taking the
                // whole connection down with it. Answer it ourselves so the
                // upstream never sees it and the rest of the session works. We
                // report success: ssh only uses the binding to restrict agent
                // forwarding, which this local proxy doesn't do anyway.
                reply = AgentMessage(type: .success)
            case .extensionRequest:
                reply = forward(message, to: upstreamFD)
            default:
                reply = Self.blockedManagementTypes.contains(message.rawType)
                    ? AgentMessage(type: .failure)
                    : forward(message, to: upstreamFD)
            }

            guard let reply, UnixSocket.writeAll(reply.encoded(), to: clientFD) else { return }
        }
    }

    /// Opens the upstream connection for a new client. If the upstream is down it
    /// asks the owner to heal it and retries once, so the first connection after
    /// the daemon has died (a long idle or a sleep/wake) succeeds rather than
    /// failing. On total failure it writes a clean `failure` to the client, asks
    /// for a background restart, and returns nil.
    private func openUpstream(for clientFD: Int32) -> Int32? {
        if let fd = connectUpstream() { return fd }
        if waitFor({ await healUpstream() }), let fd = connectUpstream() { return fd }
        onUpstreamFailure()
        _ = UnixSocket.writeAll(AgentMessage(type: .failure).encoded(), to: clientFD)
        return nil
    }

    /// Connects to the upstream daemon, capping how long a reply read may block so
    /// a hung daemon can't pin this connection's thread indefinitely.
    private func connectUpstream() -> Int32? {
        guard let fd = try? UnixSocket.connect(to: upstreamPath) else { return nil }
        UnixSocket.setReadTimeout(Self.upstreamReadTimeout, on: fd)
        return fd
    }

    /// Gates a signature on approval. When allowed, the request is forwarded and
    /// the upstream reply relayed; when denied, the client gets a `failure` and
    /// the upstream never sees the request.
    private func handleSignRequest(
        _ message: AgentMessage,
        client: RequestingProgram,
        peer: VerifiedPeer,
        upstreamFD: Int32
    ) -> AgentMessage? {
        let keyBlob = message.signRequestKeyBlob ?? Data()
        let fingerprint = SSHKeyFingerprint.of(keyBlob)
        let keyName = resolveKeyName(fingerprint: fingerprint, upstreamFD: upstreamFD)
        let request = SignRequest(client: client, peer: peer, fingerprint: fingerprint, keyName: keyName)

        let allowed = waitFor { await authorizer.authorize(request) }
        guard allowed else { return AgentMessage(type: .failure) }

        let reply = forward(message, to: upstreamFD)
        // We approved this signature, so a failure (or a dropped reply) comes from
        // the upstream agent, not the user, and its session has likely gone stale.
        // Heal the daemon so the client's retry signs cleanly.
        if reply == nil || reply?.type == .failure {
            onUpstreamFailure()
        }
        return reply
    }

    /// The human name for a key, from the snoop cache, or by asking the upstream
    /// for its identity list when the cache hasn't seen it (e.g. a client that
    /// signs without first listing keys).
    private func resolveKeyName(fingerprint: String, upstreamFD: Int32) -> String? {
        if let cached = waitFor({ await keyNameCache.name(for: fingerprint) }) {
            return cached
        }
        guard let reply = forward(AgentMessage(type: .requestIdentities), to: upstreamFD),
              reply.type == .identitiesAnswer else { return nil }
        let identities = SSHIdentitiesAnswer.parse(reply.payload)
        waitForVoid { await keyNameCache.update(with: identities) }
        return waitFor { await keyNameCache.name(for: fingerprint) }
    }

    /// Sends a message upstream and reads the single reply.
    private func forward(_ message: AgentMessage, to upstreamFD: Int32) -> AgentMessage? {
        guard UnixSocket.writeAll(message.encoded(), to: upstreamFD) else { return nil }
        return (try? AgentMessage.read(from: upstreamFD)) ?? nil
    }

    /// Records the key names from an identities reply, then passes it through.
    private func snoopIdentities(_ reply: AgentMessage) -> AgentMessage {
        if reply.type == .identitiesAnswer {
            let identities = SSHIdentitiesAnswer.parse(reply.payload)
            waitForVoid { await keyNameCache.update(with: identities) }
        }
        return reply
    }

    private func identifyClient(fd: Int32) -> RequestingProgram {
        guard let pid = SystemPeerProcessInfo.peerPID(of: fd) else { return .unknown }
        return identifier.identify(pid: pid)
    }

    /// Bridges an async actor call to this connection's blocking thread. Safe
    /// because the thread is dedicated to one connection; it isn't the main
    /// thread, so blocking it only stalls this client.
    private func waitFor<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private func waitForVoid(_ operation: @escaping @Sendable () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await operation()
            semaphore.signal()
        }
        semaphore.wait()
    }
}

/// A one-shot box to carry an async result back across the semaphore. Written
/// once before the wait returns, then read; no concurrent access.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
