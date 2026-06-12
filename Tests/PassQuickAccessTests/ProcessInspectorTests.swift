// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

private struct FakeProcessInfo: PeerProcessInfoProviding {
    let table: [pid_t: PeerProcessInfo]
    func info(for pid: pid_t) -> PeerProcessInfo? { table[pid] }
}

final class ProcessInspectorTests: XCTestCase {
    func testBatchModeDetection() {
        XCTAssertTrue(ProcessInspector.isBatchMode(["ssh", "-o", "BatchMode=yes", "host"]))
        XCTAssertTrue(ProcessInspector.isBatchMode(["ssh", "-oBatchMode=yes", "host"]))
        XCTAssertTrue(ProcessInspector.isBatchMode(["ssh", "-o", "BatchMode", "yes", "host"]))
        XCTAssertFalse(ProcessInspector.isBatchMode(["ssh", "host"]))
        XCTAssertFalse(ProcessInspector.isBatchMode(["ssh", "-o", "BatchMode=no", "host"]))
    }

    func testSSHSpawnedByGitIsNamedAfterGit() {
        let provider = FakeProcessInfo(table: [
            100: PeerProcessInfo(pid: 100, name: "ssh", arguments: ["ssh", "git@github.com"], parentPID: 50),
            50: PeerProcessInfo(pid: 50, name: "git", arguments: ["git", "fetch", "--all"], parentPID: 1),
        ])
        let info = ProcessInspector(provider: provider).identify(pid: 100)
        XCTAssertEqual(info.name, "git")
        XCTAssertEqual(info.command, "git fetch")
        XCTAssertTrue(info.showCommand)
        XCTAssertFalse(info.batchMode)
    }

    func testDirectSSHKeepsItsOwnNameAndFlagsBatchMode() {
        let provider = FakeProcessInfo(table: [
            200: PeerProcessInfo(pid: 200, name: "ssh", arguments: ["ssh", "-o", "BatchMode=yes", "git@h"], parentPID: 30),
            30: PeerProcessInfo(pid: 30, name: "zsh", arguments: ["-zsh"], parentPID: 1),
        ])
        let info = ProcessInspector(provider: provider).identify(pid: 200)
        XCTAssertEqual(info.name, "ssh")
        XCTAssertTrue(info.batchMode)
    }

    func testUnknownPidIsUnknownClient() {
        let info = ProcessInspector(provider: FakeProcessInfo(table: [:])).identify(pid: 999)
        XCTAssertEqual(info, .unknown)
    }
}
