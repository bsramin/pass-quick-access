// SPDX-License-Identifier: GPL-3.0-only

import LocalAuthentication
import XCTest
@testable import PassQuickAccess

@MainActor
final class PATReconnectorTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/true")

    func testReconnectsWhenTokenPresent() async {
        let runner = SessionRunner(initiallyUp: false)
        let reconnector = makeReconnector(runner: runner, hasToken: true)
        var recovered = false
        reconnector.onReconnected = { recovered = true }

        let restored = await reconnector.reconnectInteractively(reason: "test")

        XCTAssertTrue(restored)
        XCTAssertTrue(recovered, "a successful reconnect should trigger the index/agent recovery")
        XCTAssertTrue(runner.loginCalled)
    }

    func testNoTokenMeansNoReconnect() async {
        let runner = SessionRunner(initiallyUp: false)
        let reconnector = makeReconnector(runner: runner, hasToken: false)

        let restored = await reconnector.reconnectIfNeeded(using: LAContext())

        XCTAssertFalse(restored)
        XCTAssertFalse(runner.loginCalled, "login must not run without a stored token")
    }

    func testSkipsLoginWhenSessionAlreadyUp() async {
        let runner = SessionRunner(initiallyUp: true)
        let reconnector = makeReconnector(runner: runner, hasToken: true)
        var recovered = false
        reconnector.onReconnected = { recovered = true }

        let restored = await reconnector.reconnectIfNeeded(using: LAContext())

        XCTAssertTrue(restored)
        XCTAssertFalse(runner.loginCalled, "no need to log in when a session is already live")
        XCTAssertFalse(recovered)
    }

    func testFailsWhenLoginDoesNotEstablishSession() async {
        let runner = SessionRunner(initiallyUp: false, loginEstablishes: false)
        let reconnector = makeReconnector(runner: runner, hasToken: true)
        var recovered = false
        reconnector.onReconnected = { recovered = true }

        let restored = await reconnector.reconnectInteractively(reason: "test")

        XCTAssertFalse(restored)
        XCTAssertFalse(recovered)
    }

    func testRestoreSessionDoesNotRunRecovery() async {
        let runner = SessionRunner(initiallyUp: false)
        let reconnector = makeReconnector(runner: runner, hasToken: true)
        var recovered = false
        reconnector.onReconnected = { recovered = true }

        let restored = await reconnector.restoreSessionIfNeeded(using: LAContext())

        XCTAssertTrue(restored)
        XCTAssertTrue(runner.loginCalled)
        XCTAssertFalse(recovered, "mid-signature restore must not restart the agent")
    }

    private func makeReconnector(runner: SessionRunner, hasToken: Bool) -> PATReconnector {
        PATReconnector(
            client: PassCLIClient(executable: executable, runner: runner),
            hasStoredToken: { hasToken },
            readToken: { _ in SensitiveString("pst_token::key") },
            authenticate: { _ in LAContext() }
        )
    }
}

/// Models the session state pass-cli would report: `test` reflects whether a
/// session is live, and `login` turns it on (unless told otherwise).
private final class SessionRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var up: Bool
    private let loginEstablishes: Bool
    private var didLogin = false

    init(initiallyUp: Bool, loginEstablishes: Bool = true) {
        self.up = initiallyUp
        self.loginEstablishes = loginEstablishes
    }

    var loginCalled: Bool {
        lock.withLock { didLogin }
    }

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        lock.withLock {
            if arguments.first == "login" {
                didLogin = true
                if loginEstablishes { up = true }
                return ProcessResult(status: 0, stdout: Data(), stderr: Data())
            }
            let stderr = up ? Data() : Data("there is no session".utf8)
            return ProcessResult(status: up ? 0 : 1, stdout: Data(), stderr: stderr)
        }
    }
}
