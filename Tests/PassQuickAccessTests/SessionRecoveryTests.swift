// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

@MainActor
final class SessionRecoveryTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/true")

    func testReportsSuccessOnceSessionAppears() async {
        let runner = CountingRunner(succeedFromCall: 3)
        let client = PassCLIClient(executable: executable, runner: runner)
        let recovery = SessionRecovery(client: client, pollInterval: .milliseconds(1), maxAttempts: 20)

        let restored = await withCheckedContinuation { continuation in
            recovery.waitForSession { continuation.resume(returning: $0) }
        }

        XCTAssertTrue(restored)
        XCTAssertEqual(runner.calls, 3, "polling should stop the moment a session appears")
    }

    func testReportsFailureAfterMaxAttempts() async {
        let runner = CountingRunner(succeedFromCall: .max)
        let client = PassCLIClient(executable: executable, runner: runner)
        let recovery = SessionRecovery(client: client, pollInterval: .milliseconds(1), maxAttempts: 4)

        let restored = await withCheckedContinuation { continuation in
            recovery.waitForSession { continuation.resume(returning: $0) }
        }

        XCTAssertFalse(restored)
        XCTAssertEqual(runner.calls, 4)
    }

    func testAuthenticationFailureRecognisesLoggedOutMessages() {
        for message in [
            "Error: This operation requires an authenticated client",
            "Command is not logout there is no session",
            "you are not logged in",
        ] {
            let error = PassCLIError.commandFailed(status: 1, stderr: message)
            XCTAssertTrue(error.isAuthenticationFailure, "should flag re-login for: \(message)")
        }

        let unrelated = PassCLIError.commandFailed(status: 1, stderr: "no item with that id")
        XCTAssertFalse(unrelated.isAuthenticationFailure)
    }
}

/// A runner that fails the `test` probe until a given call number, then succeeds,
/// standing in for a login that lands partway through polling.
private final class CountingRunner: ProcessRunning, @unchecked Sendable {
    private let succeedFromCall: Int
    private let lock = NSLock()
    private var count = 0

    init(succeedFromCall: Int) {
        self.succeedFromCall = succeedFromCall
    }

    var calls: Int {
        lock.withLock { count }
    }

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        let attempt = lock.withLock {
            count += 1
            return count
        }

        if attempt >= succeedFromCall {
            return ProcessResult(status: 0, stdout: Data(), stderr: Data())
        }
        return ProcessResult(status: 1, stdout: Data(), stderr: Data("there is no session".utf8))
    }
}
