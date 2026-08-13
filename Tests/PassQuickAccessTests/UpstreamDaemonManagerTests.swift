// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

/// The reports are verbatim from pass-cli 2.3.1, since the state is only ever
/// readable from the text: `daemon status` exits 0 whether it is up or down.
final class UpstreamDaemonManagerTests: XCTestCase {
    func testReadsARunningDaemon() {
        let report = """
        Status:   running
        PID:      16870
        Socket:   /Users/someone/.ssh/proton-pass-agent.sock
        """
        XCTAssertEqual(UpstreamDaemonManager.state(fromStatus: report), .running)
    }

    func testReadsAStoppedDaemon() {
        let report = """
        Status:   stopped
        PID file: /Users/someone/.ssh/proton-pass-agent.pid (not found)
        """
        XCTAssertEqual(UpstreamDaemonManager.state(fromStatus: report), .stopped)
    }

    func testADeadProcessLeavingItsSocketBehindIsStopped() {
        let report = """
        Status:   stopped (process died, stale socket file present)
        PID:      88627 (not running)
        Socket:   /Users/someone/.ssh/proton-pass-agent.sock (stale)

        Hint:     run 'ssh-agent daemon start' to start the daemon.
        """
        XCTAssertEqual(
            UpstreamDaemonManager.state(fromStatus: report), .stopped,
            "the hint mentions starting and the PID line says 'not running', neither of which is the state"
        )
    }

    func testWordingWeDoNotRecogniseIsUnknown() {
        XCTAssertEqual(UpstreamDaemonManager.state(fromStatus: "Status:   perplexed"), .unknown)
        XCTAssertEqual(UpstreamDaemonManager.state(fromStatus: ""), .unknown)
        XCTAssertEqual(
            UpstreamDaemonManager.state(fromStatus: "error: unrecognized subcommand 'status'"), .unknown,
            "an older pass-cli must fall back to the unconditional stop, not to 'stopped'"
        )
    }
}
