// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

final class PassCLIClientTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/true")

    func testDecodesVaults() async throws {
        let runner = FakeProcessRunner(stdout: """
        {"vaults": [
          {"name": "Personal", "vault_id": "v1", "share_id": "s1"},
          {"name": "Work", "vault_id": "v2", "share_id": "s2"}
        ]}
        """)
        let client = PassCLIClient(executable: executable, runner: runner)

        let vaults = try await client.vaults()

        XCTAssertEqual(vaults.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(vaults.first?.shareID, "s1")
        XCTAssertEqual(vaults.first?.vaultID, "v1")
    }

    func testLoginItemsProjectMetadataAndDropNonLogins() async throws {
        let runner = FakeProcessRunner(stdout: loginListJSON)
        let client = PassCLIClient(executable: executable, runner: runner)

        let items = try await client.loginItems(in: Vault(name: "Personal", vaultID: "v1", shareID: "s1"))

        XCTAssertEqual(items.count, 2, "the note item should be dropped")
        let github = try XCTUnwrap(items.first)
        XCTAssertEqual(github.title, "GitHub")
        XCTAssertEqual(github.username, "octocat")
        XCTAssertEqual(github.vaultName, "Personal")
        XCTAssertEqual(github.account, "octocat")
        XCTAssertEqual(github.urls, ["https://github.com"])
        XCTAssertEqual(github.reference, ItemReference(shareID: "s1", itemID: "i1"))

        let bare = items[1]
        XCTAssertNil(bare.username)
        XCTAssertEqual(bare.email, "a@ramin.it")
        XCTAssertEqual(bare.urls, [])
    }

    func testIndexCoversEveryVault() async throws {
        let client = PassCLIClient(executable: executable, runner: twoVaultRunner())

        var items: [ItemSummary] = []
        for try await vault in client.indexLoginItems() {
            items.append(contentsOf: vault.items)
        }

        XCTAssertEqual(Set(items.map(\.shareID)), ["sa", "sb"])
        XCTAssertEqual(items.count, 2)
    }

    func testIndexStreamsOneVaultAtATime() async throws {
        let client = PassCLIClient(executable: executable, runner: twoVaultRunner())

        var positions: [Int] = []
        var totals: [Int] = []
        for try await vault in client.indexLoginItems() {
            positions.append(vault.position)
            totals.append(vault.total)
            XCTAssertEqual(vault.items.count, 1, "each chunk carries just its own vault's items")
        }

        XCTAssertEqual(positions, [1, 2], "vaults arrive in order, one at a time")
        XCTAssertEqual(totals, [2, 2])
    }

    func testExecutionsNeverOverlap() async throws {
        // pass-cli shares one session across every process, and Proton rotates the
        // session token on use, so two processes at once race that rotation and log
        // the user out. The client must run them strictly one at a time.
        let runner = ConcurrencyProbeRunner(stdout: "hunter2")
        let client = PassCLIClient(executable: executable, runner: runner)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    _ = try? await client.password(for: ItemReference(shareID: "s1", itemID: "i\(index)"))
                }
            }
        }

        XCTAssertEqual(runner.maxConcurrent, 1, "pass-cli processes must never overlap")
    }

    func testPasswordIsTrimmedAndConcealed() async throws {
        let runner = FakeProcessRunner(stdout: "hunter2\n")
        let client = PassCLIClient(executable: executable, runner: runner)

        let password = try await client.password(for: ItemReference(shareID: "s1", itemID: "i1"))

        XCTAssertEqual(password.reveal(), "hunter2")
        XCTAssertEqual(String(describing: password), "••••••")
    }

    func testTOTPDecodesCodeFromJSON() async throws {
        let runner = FakeProcessRunner(stdout: #"{"totp_uri": "281898", "totp": "281898"}"#)
        let client = PassCLIClient(executable: executable, runner: runner)

        let code = try await client.totp(for: ItemReference(shareID: "s1", itemID: "i1"))

        XCTAssertEqual(code.reveal(), "281898")
        XCTAssertEqual(String(describing: code), "••••••")
    }

    func testEmptyFieldThrows() async throws {
        let runner = FakeProcessRunner(stdout: "   \n")
        let client = PassCLIClient(executable: executable, runner: runner)

        await XCTAssertThrowsErrorAsync(try await client.field("password", of: ItemReference(shareID: "s1", itemID: "i1"))) { error in
            guard case PassCLIError.emptyValue = error else {
                return XCTFail("Expected .emptyValue, got \(error)")
            }
        }
    }

    func testNonZeroExitSurfacesStderr() async throws {
        let runner = FakeProcessRunner(stdout: "", stderr: "you are not logged in", status: 1)
        let client = PassCLIClient(executable: executable, runner: runner)

        await XCTAssertThrowsErrorAsync(try await client.vaults()) { error in
            XCTAssertEqual((error as? PassCLIError)?.isAuthenticationFailure, true)
        }
    }

    func testPATLoginPassesTokenThroughEnvironmentNotArguments() async throws {
        let runner = CapturingRunner()
        let client = PassCLIClient(executable: executable, runner: runner)
        let token = "pst_secrettoken::secretkey"

        try await client.login(withPAT: SensitiveString(token))

        XCTAssertEqual(runner.arguments, ["login"])
        XCTAssertEqual(runner.environment?["PROTON_PASS_PERSONAL_ACCESS_TOKEN"], token)
        XCTAssertFalse(runner.arguments.contains(token), "the token must never appear in argv")
    }

    func testLostSessionMessagesAreAuthenticationFailures() {
        for message in [
            "Error: you are not logged in",
            "there is no session, please log in",
            "your session expired",
            "request unauthorized",
        ] {
            let error = PassCLIError.commandFailed(status: 1, stderr: message)
            XCTAssertTrue(error.isAuthenticationFailure, "\"\(message)\" should read as signed-out")
        }
    }

    func testTransientErrorMentioningSessionIsNotAuthenticationFailure() {
        // A non-auth error that merely contains the word "session" must not flip
        // the panel to the signed-out prompt.
        let error = PassCLIError.commandFailed(status: 1, stderr: "failed to refresh session token: network timeout")
        XCTAssertFalse(error.isAuthenticationFailure)
    }

    func testSessionProbeAsksForTheVaultListOnly() async {
        let runner = CapturingRunner()
        let client = PassCLIClient(executable: executable, runner: runner)

        try? await client.verifySession()

        XCTAssertEqual(runner.arguments, ["vault", "list"])
    }

    func testARemovedSubcommandReadsAsUnsupportedRatherThanSignedOut() async {
        let error = PassCLIError.commandFailed(status: 2, stderr: "error: unrecognized subcommand 'test'")
        XCTAssertTrue(error.isUnsupportedCommand)
        XCTAssertFalse(error.isAuthenticationFailure)

        let runner = FakeProcessRunner(stdout: "", stderr: "error: unrecognized subcommand 'test'", status: 2)
        let client = PassCLIClient(executable: executable, runner: runner)
        let hasSession = await client.hasSession()
        XCTAssertTrue(hasSession, "an unrecognised probe says nothing about the session")
    }

    func testSessionLockSerialisesConcurrentHolders() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pqa-session-lock-\(UUID().uuidString)")
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    guard let token = await SessionLock.acquire(at: url) else { return }
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(10))
                    await counter.leave()
                    token.release()
                }
            }
        }

        let peak = await counter.peak
        XCTAssertEqual(peak, 1, "the session lock must let only one holder run at a time")
    }
}

/// Tracks how many tasks hold a resource at once, so a test can prove the lock
/// keeps them from overlapping.
private actor ConcurrencyCounter {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() { current -= 1 }
}

// MARK: - Fixtures

/// Two vaults, each with a single login item, so a test can drive the index.
private func twoVaultRunner() -> FakeProcessRunner {
    FakeProcessRunner { arguments in
        if arguments.contains("vault") {
            return .ok("""
            {"vaults": [
              {"name": "A", "vault_id": "va", "share_id": "sa"},
              {"name": "B", "vault_id": "vb", "share_id": "sb"}
            ]}
            """)
        }
        let share = arguments.firstValue(after: "--share-id") ?? "?"
        return .ok(singleLoginJSON(share: share))
    }
}

private let loginListJSON = """
{"items": [
  {"id": "i1", "share_id": "s1", "vault_id": "v1", "modify_time": "2026-01-01T00:00:00",
   "content": {"title": "GitHub", "note": "", "item_uuid": "u1", "extra_fields": [],
     "content": {"Login": {"email": "", "username": "octocat",
       "password": "do-not-decode", "urls": ["https://github.com"], "totp_uri": "", "passkeys": []}}}},
  {"id": "i2", "share_id": "s1", "vault_id": "v1", "modify_time": "2026-01-01T00:00:00",
   "content": {"title": "Bank", "note": "", "item_uuid": "u2", "extra_fields": [],
     "content": {"Login": {"email": "a@ramin.it", "username": "",
       "password": "do-not-decode", "urls": [""], "totp_uri": "", "passkeys": []}}}},
  {"id": "i3", "share_id": "s1", "vault_id": "v1", "modify_time": "2026-01-01T00:00:00",
   "content": {"title": "A note", "note": "secret", "item_uuid": "u3", "extra_fields": [],
     "content": {"Note": {}}}}
]}
"""

private func singleLoginJSON(share: String) -> String {
    """
    {"items": [
      {"id": "i-\(share)", "share_id": "\(share)", "vault_id": "v", "modify_time": "2026-01-01T00:00:00",
       "content": {"title": "Item", "note": "", "item_uuid": "u", "extra_fields": [],
         "content": {"Login": {"email": "", "username": "user",
           "password": "do-not-decode", "urls": [], "totp_uri": "", "passkeys": []}}}}
    ]}
    """
}

// MARK: - Test doubles & helpers

private struct FakeProcessRunner: ProcessRunning {
    private let handler: @Sendable ([String]) -> ProcessResult

    init(handler: @escaping @Sendable ([String]) -> ProcessResult) {
        self.handler = handler
    }

    init(stdout: String, stderr: String = "", status: Int32 = 0) {
        self.init { _ in
            ProcessResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
        }
    }

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        handler(arguments)
    }
}

/// Tracks how many `run` calls are in flight at once, so a test can prove the
/// client serializes them. Each call lingers briefly to widen the window an
/// overlap would land in.
private final class ConcurrencyProbeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxConcurrent = 0
    private let stdout: String

    init(stdout: String) { self.stdout = stdout }

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        lock.withLock {
            current += 1
            maxConcurrent = max(maxConcurrent, current)
        }
        try? await Task.sleep(for: .milliseconds(20))
        lock.withLock { current -= 1 }
        return ProcessResult(status: 0, stdout: Data(stdout.utf8), stderr: Data())
    }
}

/// Records the last invocation so a test can assert how a command was spawned.
private final class CapturingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var arguments: [String] = []
    private(set) var environment: [String: String]?

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        lock.withLock {
            self.arguments = arguments
            self.environment = environment
        }
        return ProcessResult(status: 0, stdout: Data(), stderr: Data())
    }
}

private extension ProcessResult {
    static func ok(_ stdout: String) -> ProcessResult {
        ProcessResult(status: 0, stdout: Data(stdout.utf8), stderr: Data())
    }
}

private extension Array where Element == String {
    func firstValue(after flag: String) -> String? {
        guard let index = firstIndex(of: flag), index + 1 < count else { return nil }
        return self[index + 1]
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        handler(error)
    }
}
