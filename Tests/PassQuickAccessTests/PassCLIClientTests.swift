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

    func testIndexFansOutAcrossEveryVault() async throws {
        let runner = FakeProcessRunner { arguments in
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
        let client = PassCLIClient(executable: executable, runner: runner)

        let items = try await client.indexLoginItems()

        XCTAssertEqual(Set(items.map(\.shareID)), ["sa", "sb"])
        XCTAssertEqual(items.count, 2)
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
}

// MARK: - Fixtures

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

    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessResult {
        handler(arguments)
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
