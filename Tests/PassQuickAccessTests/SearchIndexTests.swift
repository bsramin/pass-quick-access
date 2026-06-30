// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

final class SearchIndexTests: XCTestCase {
    private let items = [
        ItemSummary(itemID: "1", shareID: "s", vaultName: "Personal", title: "GitHub", username: "octocat", urls: ["https://github.com"]),
        ItemSummary(itemID: "2", shareID: "s", vaultName: "Work", title: "GitLab", username: "me", urls: ["https://gitlab.com"]),
        ItemSummary(itemID: "3", shareID: "s", vaultName: "Personal", title: "Bank", username: "x", urls: ["https://my.bank.example"]),
    ]

    func testEmptyQueryReturnsEverythingSortedByTitle() {
        let index = SearchIndex(items: items)
        XCTAssertEqual(index.search("", sortOrder: .alphabetical).map(\.title), ["Bank", "GitHub", "GitLab"])
    }

    func testSubstringMatchInTitleAndAcrossFields() {
        let index = SearchIndex(items: items)
        XCTAssertEqual(Set(index.search("git", sortOrder: .alphabetical).map(\.title)), ["GitHub", "GitLab"])
        XCTAssertEqual(index.search("octocat", sortOrder: .alphabetical).map(\.title), ["GitHub"])
        XCTAssertEqual(index.search("bank.example", sortOrder: .alphabetical).map(\.title), ["Bank"])
    }

    func testSubstringNotSubsequence() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "V", title: "Comunica"),
            ItemSummary(itemID: "2", shareID: "s", vaultName: "V", title: "Soluzioni Monster Crea un account"),
        ])
        // "unica" is a substring of "Comunica" but only a scattered subsequence
        // of the long title, which must not match.
        XCTAssertEqual(index.search("unica", sortOrder: .alphabetical).map(\.title), ["Comunica"])
    }

    func testDiacriticsAreIgnored() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "V", title: "Café Münchën"),
        ])
        XCTAssertEqual(index.search("cafe munchen", sortOrder: .alphabetical).count, 1)
    }

    func testNonMatchingQueryReturnsNothing() {
        let index = SearchIndex(items: items)
        XCTAssertTrue(index.search("zzzzz", sortOrder: .alphabetical).isEmpty)
    }

    func testMultiTokenRequiresEveryToken() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "Personal", title: "Acme - alice@example.com", email: "alice@example.com"),
            ItemSummary(itemID: "2", shareID: "s", vaultName: "Personal", title: "Acme - bob@example.com", email: "bob@example.com"),
            ItemSummary(itemID: "3", shareID: "s", vaultName: "Personal", title: "Globex - Carol", email: "carol@example.com"),
            ItemSummary(itemID: "4", shareID: "s", vaultName: "Shop", title: "Initech", email: "dave@example.com"),
        ])

        XCTAssertEqual(index.search("acme alice", sortOrder: .alphabetical).map(\.title), ["Acme - alice@example.com"])
        XCTAssertEqual(index.search("acme", sortOrder: .alphabetical).count, 2)
    }

    func testMatchesNoteAndCustomFields() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "V", title: "Router",
                        note: "admin panel 192.168.1.1", customFields: ["Recovery", "blue-whale-42"]),
            ItemSummary(itemID: "2", shareID: "s", vaultName: "V", title: "Other"),
        ])

        XCTAssertEqual(index.search("192.168", sortOrder: .alphabetical).map(\.title), ["Router"])
        XCTAssertEqual(index.search("blue-whale", sortOrder: .alphabetical).map(\.title), ["Router"])
    }

    func testMostRecentlyModifiedComesFirst() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "V", title: "Alpha", modifyTime: "2026-06-01T10:00:00"),
            ItemSummary(itemID: "2", shareID: "s", vaultName: "V", title: "Zebra", modifyTime: "2026-06-10T10:00:00"),
        ])
        // Newer first under lastModified, even though "Zebra" sorts after "Alpha".
        XCTAssertEqual(index.search("", sortOrder: .lastModified).map(\.title), ["Zebra", "Alpha"])
        XCTAssertEqual(index.search("", sortOrder: .alphabetical).map(\.title), ["Alpha", "Zebra"])
    }

    func testTitleMatchOutranksABuriedFieldMatch() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "V", title: "Alpha", note: "backup git repo"),
            ItemSummary(itemID: "2", shareID: "s", vaultName: "V", title: "Zenith Git Host"),
        ])
        // Both contain "git", but the title hit outranks the note hit, even though
        // alphabetically "Alpha" would come first.
        XCTAssertEqual(index.search("git", sortOrder: .alphabetical).map(\.title), ["Zenith Git Host", "Alpha"])
    }

    func testPrefixOutranksMidWordInTitle() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "V", title: "Digital Ocean"),
            ItemSummary(itemID: "2", shareID: "s", vaultName: "V", title: "Gitea"),
        ])
        // "Gitea" starts with the query; "Digital" only contains it mid-word.
        XCTAssertEqual(index.search("git", sortOrder: .alphabetical).map(\.title), ["Gitea", "Digital Ocean"])
    }

    func testFrequentlyUsedComesFirstWhenPrioritized() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "V", title: "Alpha", modifyTime: "2026-06-01T10:00:00"),
            ItemSummary(itemID: "2", shareID: "s", vaultName: "V", title: "Beta", modifyTime: "2026-06-02T10:00:00"),
            ItemSummary(itemID: "3", shareID: "s", vaultName: "V", title: "Gamma", modifyTime: "2026-06-03T10:00:00"),
        ], usage: ["s/2": 5, "s/1": 1])
        // Beta is used most, Alpha once, Gamma never, regardless of title or date.
        XCTAssertEqual(index.search("", sortOrder: .lastModified, prioritizeUsage: true).map(\.title), ["Beta", "Alpha", "Gamma"])
    }

    func testUsageIsIgnoredWhenNotPrioritized() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "V", title: "Alpha", modifyTime: "2026-06-01T10:00:00"),
            ItemSummary(itemID: "2", shareID: "s", vaultName: "V", title: "Beta", modifyTime: "2026-06-02T10:00:00"),
        ], usage: ["s/1": 99])
        // With the opt-in off, the order is the plain sort, not usage.
        XCTAssertEqual(index.search("", sortOrder: .lastModified).map(\.title), ["Beta", "Alpha"])
    }

    func testPrioritizedUsageFallsBackToRecencyForUnusedItems() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "V", title: "Old", modifyTime: "2026-06-01T10:00:00"),
            ItemSummary(itemID: "2", shareID: "s", vaultName: "V", title: "New", modifyTime: "2026-06-09T10:00:00"),
        ])
        // Never-used items all tie at zero, so the most recent leads.
        XCTAssertEqual(index.search("", sortOrder: .lastModified, prioritizeUsage: true).map(\.title), ["New", "Old"])
    }

    func testPrioritizedUsageBreaksSearchScoreTies() {
        let index = SearchIndex(items: [
            ItemSummary(itemID: "1", shareID: "s", vaultName: "V", title: "Git One"),
            ItemSummary(itemID: "2", shareID: "s", vaultName: "V", title: "Git Two"),
        ], usage: ["s/2": 3])
        // Both match "git" with the same score; the more-used one wins the tie.
        XCTAssertEqual(index.search("git", sortOrder: .lastModified, prioritizeUsage: true).map(\.title), ["Git Two", "Git One"])
    }

    @MainActor
    func testUsageTrackerRecordsOnlyWhenOptedIn() {
        let defaults = UserDefaults(suiteName: "pqa-usage-\(UUID().uuidString)")!
        let tracker = UsageTracker(defaults: defaults)

        // Off by default: a use leaves nothing stored.
        tracker.record("s/1")
        XCTAssertTrue(tracker.snapshot.isEmpty)

        // Opted in: uses accumulate.
        defaults.set(true, forKey: SettingKey.prioritizeFrequentlyUsed)
        tracker.record("s/1")
        tracker.record("s/1")
        XCTAssertEqual(tracker.snapshot["s/1"], 2)
    }

    func testSpansMultipleVaults() {
        XCTAssertTrue(SearchIndex(items: items).spansMultipleVaults)
        let single = [ItemSummary(itemID: "1", shareID: "s", vaultName: "Solo", title: "A")]
        XCTAssertFalse(SearchIndex(items: single).spansMultipleVaults)
    }
}
