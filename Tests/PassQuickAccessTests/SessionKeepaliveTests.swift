// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

@MainActor
final class SessionKeepaliveTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/true")
    private var reportedLost = false

    func testPingProbesTheSessionWithoutReadingTheVaults() async {
        let runner = RecordingRunner()
        let keepalive = makeKeepalive(runner: runner)

        await keepalive.ping()

        XCTAssertEqual(runner.commands, [["test"]], "a keepalive that listed items would fight the SSH agent for the session lock")
        XCTAssertFalse(reportedLost)
    }

    func testPingReportsALapsedSession() async {
        let keepalive = makeKeepalive(runner: RecordingRunner(status: 1, stderr: "there is no session"))

        await keepalive.ping()

        XCTAssertTrue(reportedLost)
    }

    func testStoppingLeavesNoPingBehind() async {
        let runner = RecordingRunner()
        let keepalive = makeKeepalive(runner: runner, interval: .milliseconds(1))

        keepalive.start()
        keepalive.stop()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(runner.commands.isEmpty, "a stopped keepalive must not keep spawning pass-cli")
    }

    private func makeKeepalive(runner: RecordingRunner, interval: Duration = .seconds(60)) -> SessionKeepalive {
        let keepalive = SessionKeepalive(client: PassCLIClient(executable: executable, runner: runner), interval: interval)
        keepalive.onSessionLost = { [weak self] in self?.reportedLost = true }
        return keepalive
    }
}

private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let status: Int32
    private let stderr: String

    init(status: Int32 = 0, stderr: String = "") {
        self.status = status
        self.stderr = stderr
    }

    var commands: [[String]] { lock.withLock { recorded } }

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        lock.withLock { recorded.append(arguments) }
        return ProcessResult(status: status, stdout: Data(), stderr: Data(stderr.utf8))
    }
}
