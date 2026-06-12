// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

final class SSHConfigInstallerTests: XCTestCase {
    private func tempConfig() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pqa-sshconfig-\(UUID().uuidString)")
            .appendingPathComponent("config")
    }

    func testInstallCreatesBlockAndPreservesExistingContent() throws {
        let url = tempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Host example\n    User me\n".write(to: url, atomically: true, encoding: .utf8)

        try SSHConfigInstaller.install(at: url)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(SSHConfigInstaller.isInstalled(at: url))
        XCTAssertTrue(contents.contains("IdentityAgent"))
        XCTAssertTrue(contents.contains("Host example"), "existing config must be preserved")
    }

    func testInstallIsIdempotent() throws {
        let url = tempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try SSHConfigInstaller.install(at: url)
        try SSHConfigInstaller.install(at: url)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let occurrences = contents.components(separatedBy: "# BEGIN Pass Quick Access").count - 1
        XCTAssertEqual(occurrences, 1, "the block must appear exactly once")
    }

    func testUninstallRemovesOnlyTheBlock() throws {
        let url = tempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Host example\n    User me\n".write(to: url, atomically: true, encoding: .utf8)

        try SSHConfigInstaller.install(at: url)
        try SSHConfigInstaller.uninstall(at: url)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(SSHConfigInstaller.isInstalled(at: url))
        XCTAssertFalse(contents.contains("IdentityAgent"))
        XCTAssertTrue(contents.contains("Host example"))
    }
}
