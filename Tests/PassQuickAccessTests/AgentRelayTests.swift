// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

private actor StaticPresenter: SignApprovalPresenting {
    let allow: Bool
    init(allow: Bool) { self.allow = allow }
    func present(_ request: SignRequest) async -> Bool { allow }
}

/// A throwaway agent listening on a Unix socket that records what it receives and
/// answers with canned replies, so the proxy can be driven end to end.
private final class FakeUpstream: @unchecked Sendable {
    let path: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var _received: [AgentMessage] = []

    var received: [AgentMessage] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    init() {
        path = "/tmp/pqa-up-\(UUID().uuidString.prefix(8)).sock"
    }

    func start() throws {
        listenFD = try UnixSocket.listen(at: path)
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            while let message = try? AgentMessage.read(from: client) {
                self?.record(message)
                let reply = Self.reply(to: message)
                _ = UnixSocket.writeAll(reply.encoded(), to: client)
            }
            close(client)
        }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        try? FileManager.default.removeItem(atPath: UnixSocket.expand(path))
    }

    private func record(_ message: AgentMessage) {
        lock.lock(); _received.append(message); lock.unlock()
    }

    private static func reply(to message: AgentMessage) -> AgentMessage {
        switch message.type {
        case .requestIdentities:
            var payload = Data()
            payload.appendBigEndianUInt32(1)
            payload.append(sshString(Array("k".utf8)))
            payload.append(sshString(Array("a key".utf8)))
            return AgentMessage(type: .identitiesAnswer, payload: payload)
        case .signRequest:
            return AgentMessage(type: .signResponse, payload: sshString([0x99]))
        default:
            return AgentMessage(type: .success)
        }
    }

    static func sshString(_ bytes: [UInt8]) -> Data {
        var data = Data()
        data.appendBigEndianUInt32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
        return data
    }
}

final class AgentRelayTests: XCTestCase {
    private func makeProxy(upstream: String, allow: Bool) -> AgentRelay {
        AgentRelay(
            upstreamPath: upstream,
            authorizer: SignAuthorizer(
                store: RememberedDecisionsStore(fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pqa-proxy-\(UUID().uuidString).json")),
                presenter: StaticPresenter(allow: allow)
            ),
            keyNameCache: KeyLabelCache(),
            identifier: ProcessInspector()
        )
    }

    /// A socketpair: the test writes/reads on one end, the proxy serves the other.
    private func makeClientPair() throws -> (mine: Int32, proxy: Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair unavailable")
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return (fds[0], fds[1])
    }

    private func signRequest(keyBlob: [UInt8]) -> AgentMessage {
        var payload = FakeUpstream.sshString(keyBlob)
        payload.append(FakeUpstream.sshString([0x01]))
        payload.appendBigEndianUInt32(0)
        return AgentMessage(type: .signRequest, payload: payload)
    }

    func testApprovedSignIsForwardedAndRelayed() throws {
        let upstream = FakeUpstream()
        try upstream.start()
        defer { upstream.stop() }

        let proxy = makeProxy(upstream: upstream.path, allow: true)
        let pair = try makeClientPair()
        DispatchQueue.global().async { proxy.handle(clientFD: pair.proxy) }

        XCTAssertTrue(UnixSocket.writeAll(AgentMessage(type: .requestIdentities).encoded(), to: pair.mine))
        let identities = try AgentMessage.read(from: pair.mine)
        XCTAssertEqual(identities?.type, .identitiesAnswer)

        XCTAssertTrue(UnixSocket.writeAll(signRequest(keyBlob: [0xab]).encoded(), to: pair.mine))
        let signed = try AgentMessage.read(from: pair.mine)
        XCTAssertEqual(signed?.type, .signResponse)

        close(pair.mine)
        XCTAssertTrue(upstream.received.contains { $0.type == .signRequest })
    }

    func testSessionBindIsAbsorbedAndNotForwarded() throws {
        let upstream = FakeUpstream()
        try upstream.start()
        defer { upstream.stop() }

        let proxy = makeProxy(upstream: upstream.path, allow: true)
        let pair = try makeClientPair()
        DispatchQueue.global().async { proxy.handle(clientFD: pair.proxy) }

        // ssh sends this extension before listing keys; pass-cli's agent breaks on
        // it, so the proxy must answer locally and keep it off the upstream.
        var payload = FakeUpstream.sshString(Array("session-bind@openssh.com".utf8))
        payload.append(contentsOf: [0x00, 0x01, 0x02])
        let bind = AgentMessage(type: .extensionRequest, payload: payload)
        XCTAssertTrue(UnixSocket.writeAll(bind.encoded(), to: pair.mine))
        let bindReply = try AgentMessage.read(from: pair.mine)
        XCTAssertEqual(bindReply?.type, .success)

        // The connection stays usable for a following request.
        XCTAssertTrue(UnixSocket.writeAll(AgentMessage(type: .requestIdentities).encoded(), to: pair.mine))
        let identities = try AgentMessage.read(from: pair.mine)
        XCTAssertEqual(identities?.type, .identitiesAnswer)

        close(pair.mine)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(upstream.received.contains { $0.rawType == 27 }, "session-bind must not reach upstream")
    }

    func testKeyManagementRequestsAreRefusedAndNotForwarded() throws {
        let upstream = FakeUpstream()
        try upstream.start()
        defer { upstream.stop() }

        let proxy = makeProxy(upstream: upstream.path, allow: true)
        let pair = try makeClientPair()
        DispatchQueue.global().async { proxy.handle(clientFD: pair.proxy) }

        // SSH_AGENTC_ADD_IDENTITY (17): a read+sign-only proxy must refuse it.
        let add = AgentMessage(rawType: 17, payload: Data([0x00]))
        XCTAssertTrue(UnixSocket.writeAll(add.encoded(), to: pair.mine))
        let reply = try AgentMessage.read(from: pair.mine)
        XCTAssertEqual(reply?.type, .failure)

        close(pair.mine)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(upstream.received.contains { $0.rawType == 17 }, "key management must not reach upstream")
    }

    func testDeniedSignNeverReachesUpstream() throws {
        let upstream = FakeUpstream()
        try upstream.start()
        defer { upstream.stop() }

        let proxy = makeProxy(upstream: upstream.path, allow: false)
        let pair = try makeClientPair()
        DispatchQueue.global().async { proxy.handle(clientFD: pair.proxy) }

        XCTAssertTrue(UnixSocket.writeAll(signRequest(keyBlob: [0xcd]).encoded(), to: pair.mine))
        let reply = try AgentMessage.read(from: pair.mine)
        XCTAssertEqual(reply?.type, .failure)

        close(pair.mine)
        // Give the upstream serve loop a moment; it must not have seen the sign.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(upstream.received.contains { $0.type == .signRequest })
    }
}
