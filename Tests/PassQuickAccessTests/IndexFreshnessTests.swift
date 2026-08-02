// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

@MainActor
final class IndexFreshnessTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/true")
    private var reconnected = false

    func testStaleIndexIsReReadAndPicksUpNewItems() async {
        let runner = VaultRunner(titles: ["GitHub"])
        let model = makeViewModel(runner: runner, freshness: 0)
        await model.reload()
        XCTAssertEqual(model.results.map(\.title), ["GitHub"])

        runner.titles = ["GitHub", "Fastmail"]
        await model.refreshIfStale()

        XCTAssertEqual(model.results.map(\.title).sorted(), ["Fastmail", "GitHub"])
    }

    func testFreshIndexIsLeftAlone() async {
        let runner = VaultRunner(titles: ["GitHub"])
        let model = makeViewModel(runner: runner, freshness: 600)
        await model.reload()
        let afterLoad = runner.calls

        await model.refreshIfStale()

        XCTAssertEqual(runner.calls, afterLoad, "a fresh index must not spawn pass-cli again")
    }

    func testExplicitRefreshIgnoresTheFreshnessWindow() async {
        let runner = VaultRunner(titles: ["GitHub"])
        let model = makeViewModel(runner: runner, freshness: 600)
        await model.reload()

        runner.titles = ["GitHub", "Fastmail"]
        await model.refreshNow()

        XCTAssertEqual(model.results.count, 2, "the menu's refresh should re-read whatever the index's age")
    }

    func testARefreshThatLosesTheSessionKeepsTheResultsAndReconnects() async {
        let runner = VaultRunner(titles: ["GitHub"])
        let model = makeViewModel(runner: runner, freshness: 0)
        await model.reload()
        model.onSilentReconnect = { [weak self] in
            self?.reconnected = true
            return true
        }

        runner.failsWith = "there is no session"
        await model.refreshIfStale()

        XCTAssertEqual(model.results.map(\.title), ["GitHub"], "a stale index beats an empty one")
        XCTAssertEqual(model.loadState, .ready, "a background refresh must never drop the panel to signed-out")
        XCTAssertTrue(reconnected)
    }

    private func makeViewModel(runner: VaultRunner, freshness: TimeInterval) -> QuickAccessViewModel {
        QuickAccessViewModel(
            client: PassCLIClient(executable: executable, runner: runner),
            indexFreshness: freshness
        )
    }
}

/// One vault whose item list can be changed between reads, standing in for a
/// login added on another device.
private final class VaultRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTitles: [String]
    private var storedFailure: String?
    private var count = 0

    init(titles: [String]) {
        storedTitles = titles
    }

    var titles: [String] {
        get { lock.withLock { storedTitles } }
        set { lock.withLock { storedTitles = newValue } }
    }

    /// Set to fail every command from then on with this on stderr.
    var failsWith: String? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    var calls: Int { lock.withLock { count } }

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        let (titles, failure) = lock.withLock {
            count += 1
            return (storedTitles, storedFailure)
        }
        if let failure {
            return ProcessResult(status: 1, stdout: Data(), stderr: Data(failure.utf8))
        }
        let stdout = arguments.contains("vault") ? Self.vaultJSON : Self.itemJSON(titles: titles)
        return ProcessResult(status: 0, stdout: Data(stdout.utf8), stderr: Data())
    }

    private static let vaultJSON = """
    {"vaults": [{"name": "Personal", "vault_id": "v1", "share_id": "s1"}]}
    """

    private static func itemJSON(titles: [String]) -> String {
        let items = titles.enumerated().map { index, title in
            """
            {"id": "i\(index)", "share_id": "s1", "vault_id": "v1", "modify_time": "2026-01-01T00:00:00",
             "content": {"title": "\(title)", "note": "", "item_uuid": "u\(index)", "extra_fields": [],
               "content": {"Login": {"email": "", "username": "user",
                 "password": "do-not-decode", "urls": [], "totp_uri": "", "passkeys": []}}}}
            """
        }
        return "{\"items\": [\(items.joined(separator: ","))]}"
    }
}
