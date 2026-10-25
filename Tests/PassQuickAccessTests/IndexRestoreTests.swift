// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

/// What a launch can answer from the cached index, and when the cache is
/// written, re-read or thrown away.
@MainActor
final class IndexRestoreTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/true")
    private let key = Data(repeating: 0x5A, count: 32)
    private var directory = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-restore-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private var cache: IndexCache {
        IndexCache(url: directory.appendingPathComponent("index.sealed"), key: key)
    }

    func testACachedIndexIsShownWithoutRunningPassCLI() async throws {
        try cache.save([makeItem(title: "GitHub")], at: Date())
        let runner = VaultRunner(titles: ["Fastmail"])
        let model = makeViewModel(runner: runner, freshness: 600)

        await model.loadIfNeeded()

        XCTAssertEqual(model.results.map(\.title), ["GitHub"], "the cached rows should be on screen")
        XCTAssertEqual(model.loadState, .ready)
        XCTAssertTrue(model.autofillIsIndexReady, "AutoFill should not wait for a vault read it doesn't need")
        XCTAssertEqual(runner.calls, 0, "a fresh cache must answer without spawning pass-cli")
    }

    func testACompletePassWritesTheIndexDown() async throws {
        let model = makeViewModel(runner: VaultRunner(titles: ["GitHub", "Fastmail"]), freshness: 600)

        await model.reload()

        XCTAssertEqual(cache.load()?.items.map(\.title).sorted(), ["Fastmail", "GitHub"])
    }

    func testACachedIndexPastItsFreshnessIsReReadAtOnce() async throws {
        try cache.save([makeItem(title: "GitHub")], at: Date(timeIntervalSince1970: 0))
        let runner = VaultRunner(titles: ["GitHub", "Fastmail"])
        let model = makeViewModel(runner: runner, freshness: 600)

        await model.loadIfNeeded()

        XCTAssertGreaterThan(runner.calls, 0, "a cache older than the window should be refreshed straight away")
        XCTAssertEqual(model.results.map(\.title).sorted(), ["Fastmail", "GitHub"])
        XCTAssertEqual(cache.load()?.items.count, 2, "the rows just read should replace the aged ones on disk")
    }

    func testARefreshThatFailsLeavesTheCachedIndexAlone() async throws {
        try cache.save([makeItem(title: "GitHub")], at: Date(timeIntervalSince1970: 0))
        let runner = VaultRunner(titles: ["GitHub", "Fastmail"])
        runner.failsWith = "could not reach the service"
        let model = makeViewModel(runner: runner, freshness: 600)

        await model.loadIfNeeded()

        XCTAssertEqual(
            cache.load()?.items.map(\.title), ["GitHub"],
            "a refresh that read nothing must not replace or drop what the cache already had"
        )
    }

    func testSigningOutTakesTheCachedIndexWithIt() async throws {
        try cache.save([makeItem(title: "GitHub")], at: Date())
        let runner = VaultRunner(titles: ["GitHub"])
        runner.failsWith = "there is no session"
        let model = makeViewModel(runner: runner, freshness: 0)

        await model.reload()

        XCTAssertNil(cache.load(), "rows nobody can read any more have no business surviving a sign-out")
    }

    private func makeItem(title: String) -> ItemSummary {
        ItemSummary(
            itemID: title.lowercased(),
            shareID: "s1",
            vaultName: "Personal",
            title: title,
            username: "user",
            urls: ["https://\(title.lowercased()).com"],
            modifyTime: "2026-01-01T00:00:00",
            hasPassword: true
        )
    }

    private func makeViewModel(runner: VaultRunner, freshness: TimeInterval) -> QuickAccessViewModel {
        QuickAccessViewModel(
            client: PassCLIClient(executable: executable, runner: runner),
            indexFreshness: freshness,
            cache: cache
        )
    }
}

/// One vault whose items can change between reads, and which can be made to
/// fail every command from a given moment.
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
