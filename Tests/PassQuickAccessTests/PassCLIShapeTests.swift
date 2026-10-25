// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

/// What `item list --show-secrets --output json` actually prints, field for
/// field, as of pass-cli 2.5.1.
///
/// The fixture below is the shape of real output rather than the subset the
/// decoder reads: every key the CLI emits is in it, including the ones the app
/// has no use for. A field added upstream must not break decoding, and one the
/// app deliberately leaves out of the index must stay out, so this is the test
/// that fails when the next CLI release changes the contract under us.
final class PassCLIShapeTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/true")
    private let vault = Vault(name: "Personal", vaultID: "v1", shareID: "s1")

    func testTheFullShapeOfTheCLIDecodes() async throws {
        let items = try await loginItems(from: Self.itemListJSON)

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.itemID, "i1")
        XCTAssertEqual(item.shareID, "s1")
        XCTAssertEqual(item.title, "GitHub")
        XCTAssertEqual(item.username, "octocat")
        XCTAssertEqual(item.email, "octocat@example.com")
        XCTAssertEqual(item.urls, ["https://github.com"])
        XCTAssertEqual(item.note, "a note")
        XCTAssertEqual(item.modifyTime, "2026-10-21T09:00:00")
        XCTAssertTrue(item.hasPassword)
        XCTAssertTrue(item.hasTOTP)
    }

    func testTheAutofillRulesStayOutOfTheIndex() async throws {
        // 2.5.0 added `autofill_urls`, a list of `{url, mode}` that today only
        // repeats urls already in `urls` with mode "Default". Folding it into
        // the index would duplicate rows in search for no gain; a mode that
        // means something other than Default is the reason to revisit it.
        let items = try await loginItems(from: Self.itemListJSON)

        XCTAssertEqual(try XCTUnwrap(items.first).urls, ["https://github.com"])
    }

    func testAHiddenCustomFieldIsSearchableByNameOnly() async throws {
        let items = try await loginItems(from: Self.itemListJSON)
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(item.customFields, ["Recovery note", "visible", "Backup code"])
        XCTAssertFalse(item.customFields.contains("do-not-decode"), "a hidden value is not metadata")
    }

    private func loginItems(from json: String) async throws -> [ItemSummary] {
        let client = PassCLIClient(executable: executable, runner: StubRunner(stdout: json))
        return try await client.loginItems(in: vault)
    }

    /// One login as pass-cli 2.5.1 prints it, with the keys the app ignores
    /// left in place: `create_time`, `state`, `flags`, `item_uuid`,
    /// `passkeys`, and the three 2.5.0 additions `autofill_urls`,
    /// `custom_icon` and `platform_specific`.
    private static let itemListJSON = """
    {"items": [
      {"id": "i1", "share_id": "s1", "vault_id": "v1",
       "create_time": "2026-01-01T00:00:00", "modify_time": "2026-10-21T09:00:00",
       "state": "Active", "flags": [],
       "content": {
         "title": "GitHub", "note": "a note", "item_uuid": "u1",
         "custom_icon": null, "platform_specific": null,
         "extra_fields": [
           {"name": "Recovery note", "content": {"Text": "visible"}},
           {"name": "Backup code", "content": {"Hidden": "do-not-decode"}}
         ],
         "content": {"Login": {
           "email": "octocat@example.com", "username": "octocat",
           "password": "do-not-decode",
           "urls": ["https://github.com"],
           "autofill_urls": [{"url": "https://github.com", "mode": "Default"}],
           "totp_uri": "do-not-decode",
           "passkeys": []
         }}
       }}
    ]}
    """
}

// MARK: - Test doubles

/// Answers every command with one canned payload.
private struct StubRunner: ProcessRunning {
    let stdout: String

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        ProcessResult(status: 0, stdout: Data(stdout.utf8), stderr: Data())
    }
}
