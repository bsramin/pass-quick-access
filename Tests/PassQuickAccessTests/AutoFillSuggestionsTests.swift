// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

@MainActor
final class AutoFillSuggestionsTests: XCTestCase {
    private func item(_ urls: [String]) -> ItemSummary {
        ItemSummary(itemID: "1", shareID: "s", vaultName: "Personal", title: "Google",
                    username: "test@gmail.com", urls: urls)
    }

    func testSubdomainsCollapseIntoTheBroaderEntry() {
        let hosts = AutoFillSuggestions.coveringHosts(of: item([
            "https://google.com",
            "https://accounts.google.com",
            "https://myaccount.google.com",
        ]))
        XCTAssertEqual(hosts, ["google.com"])
    }

    func testDuplicateURLsRegisterOnce() {
        let hosts = AutoFillSuggestions.coveringHosts(of: item([
            "https://www.example.com/login",
            "example.com",
            "https://example.com/account/settings",
        ]))
        XCTAssertEqual(hosts, ["example.com"])
    }

    /// Only a host the item itself covers is dropped. Two subdomains with no
    /// parent between them are separate entries as far as this can tell.
    func testUnrelatedHostsAreAllKept() {
        let hosts = AutoFillSuggestions.coveringHosts(of: item([
            "https://google.com",
            "https://youtube.com",
            "https://mail.proton.me",
        ]))
        XCTAssertEqual(hosts, ["google.com", "mail.proton.me", "youtube.com"])
    }

    func testAHostIsNotTreatedAsCoveringItself() {
        XCTAssertEqual(AutoFillSuggestions.coveringHosts(of: item(["example.com"])), ["example.com"])
    }

    /// A shared suffix that isn't a domain boundary is not a parent: notexample
    /// .com must not swallow example.com.
    func testASharedSuffixIsNotASubdomain() {
        let hosts = AutoFillSuggestions.coveringHosts(of: item([
            "https://example.com",
            "https://notexample.com",
        ]))
        XCTAssertEqual(hosts, ["example.com", "notexample.com"])
    }
}
