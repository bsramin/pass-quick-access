// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

/// Which of the two waits the panel is in. The footer carries the keyboard
/// hints, so progress may only take it over while the rows behind it are still
/// arriving; a refresh runs behind a list that is already complete and has no
/// business hiding the shortcuts for the seconds it takes.
@MainActor
final class IndexingProgressTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/true")

    func testTheFirstPassSaysTheListIsStillFillingIn() async throws {
        let runner = GatedRunner(vaults: 2, holding: "s2")
        let model = makeViewModel(runner: runner)

        let pass = Task { await model.reload() }
        await waitUntil { !model.results.isEmpty }

        XCTAssertTrue(model.isBuildingList, "one vault's rows are not the whole list yet")

        runner.release()
        await pass.value
    }

    func testARefreshBehindACompleteListIsNotBuildingIt() async throws {
        let runner = GatedRunner(vaults: 1, holding: nil)
        let model = makeViewModel(runner: runner)
        await model.reload()
        runner.hold("s1")

        let refresh = Task { await model.refreshNow() }
        await waitUntil { model.isIndexing }

        XCTAssertFalse(model.results.isEmpty, "the list from the last pass stays up")
        XCTAssertFalse(model.isBuildingList, "nothing on screen is in doubt, so the hints stay")

        runner.release()
        await refresh.value
    }

    func testTheListStopsBuildingWhenThePassEnds() async throws {
        let model = makeViewModel(runner: GatedRunner(vaults: 2, holding: nil))

        await model.reload()

        XCTAssertFalse(model.isBuildingList)
        XCTAssertFalse(model.isIndexing)
    }

    private func makeViewModel(runner: GatedRunner) -> QuickAccessViewModel {
        QuickAccessViewModel(
            client: PassCLIClient(executable: executable, runner: runner),
            indexFreshness: 600
        )
    }

    /// Polls the main actor until the condition holds, so a test can catch a
    /// state the view model passes through on its way somewhere else.
    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for the expected state", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Test doubles

/// Vaults that can be stopped partway, so a test can look at the panel while a
/// pass is still in flight. The read of one named share waits until the test
/// lets it through; every other command answers at once.
private final class GatedRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let vaults: Int
    private var heldShare: String?
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(vaults: Int, holding: String?) {
        self.vaults = vaults
        heldShare = holding
    }

    func hold(_ share: String) {
        lock.withLock {
            heldShare = share
            released = false
        }
    }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting = [] }
            return waiting
        }
        pending.forEach { $0.resume() }
    }

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        if arguments.contains("vault") {
            return ProcessResult(status: 0, stdout: Data(vaultJSON.utf8), stderr: Data())
        }
        let share = shareID(in: arguments) ?? "s1"
        if arguments.contains("list"), isHeld(share) { await waitForRelease() }
        return ProcessResult(status: 0, stdout: Data(Self.itemJSON(share: share).utf8), stderr: Data())
    }

    private func isHeld(_ share: String) -> Bool {
        lock.withLock { heldShare == share && !released }
    }

    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            // Checked under the same lock as `release`, so a release that lands
            // between the two never leaves the read waiting for a second one.
            let alreadyReleased = lock.withLock { () -> Bool in
                guard !released else { return true }
                waiting.append(continuation)
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
    }

    private func shareID(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--share-id"), arguments.count > flag + 1 else { return nil }
        return arguments[flag + 1]
    }

    private var vaultJSON: String {
        let entries = (1...vaults).map {
            """
            {"name": "Vault \($0)", "vault_id": "v\($0)", "share_id": "s\($0)"}
            """
        }
        return "{\"vaults\": [\(entries.joined(separator: ","))]}"
    }

    private static func itemJSON(share: String) -> String {
        """
        {"items": [
          {"id": "i-\(share)", "share_id": "\(share)", "vault_id": "v", "modify_time": "2026-01-01T00:00:00",
           "content": {"title": "Item in \(share)", "note": "", "item_uuid": "u-\(share)", "extra_fields": [],
             "content": {"Login": {"email": "", "username": "user",
               "password": "do-not-decode", "urls": [], "totp_uri": "", "passkeys": []}}}}
        ]}
        """
    }
}
