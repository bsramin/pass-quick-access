// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// In-memory search over the login index. Matching reproduces Proton Pass's own
/// matcher (packages/pass/lib/search/match-items.ts): normalize, split the query
/// into space-separated needles, and keep items where every needle is a substring
/// of some searchable field. On top of that it ranks the matches by where they hit
/// (a title beats a username beats a buried URL or note, and a prefix beats a
/// mid-word match), so the most relevant items come first.
struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        let item: ItemSummary
        let searchable: String
        /// Normalized title and account, kept apart from the rest for ranking.
        let title: String
        let account: String
    }

    private let entries: [Entry]
    /// How many times each item (by id) has been used, for the most-used order.
    private let usage: [String: Int]

    /// True when items span more than one vault, so the UI should disambiguate
    /// results with a vault badge.
    let spansMultipleVaults: Bool

    init(items: [ItemSummary], usage: [String: Int] = [:]) {
        entries = items.map { item in
            Entry(
                item: item,
                searchable: Self.searchableText(for: item),
                title: Self.normalize(item.title),
                account: Self.normalize([item.username, item.email].compactMap { $0 }.joined(separator: " "))
            )
        }
        self.usage = usage
        spansMultipleVaults = Set(items.map(\.vaultName)).count > 1
    }

    /// Every indexed item, so the list can be rebuilt against fresh usage counts
    /// without re-reading the vaults.
    var allItems: [ItemSummary] { entries.map(\.item) }

    /// Every item whose stored URL matches `host`, most recently modified first,
    /// scanning the whole index rather than the capped result list so a match
    /// isn't missed for a login outside the top results.
    func items(matchingHost host: String) -> [ItemSummary] {
        entries.map(\.item)
            .filter { $0.urls.contains { WebHost.from($0).map { WebHost.matches(host, $0) } ?? false } }
            .sorted { $0.modifyTime > $1.modifyTime }
    }

    func search(_ rawQuery: String, sortOrder: SortOrder, prioritizeUsage: Bool = false, limit: Int = 200) -> [ItemSummary] {
        let needles = Self.needles(from: rawQuery)
        let ordered = areInOrder(sortOrder, prioritizeUsage: prioritizeUsage)
        guard !needles.isEmpty else {
            return Array(entries.map(\.item).sorted(by: ordered).prefix(limit))
        }

        let scored = entries
            .filter { entry in needles.allSatisfy(entry.searchable.contains) }
            .map { entry in (item: entry.item, score: Self.score(entry, needles: needles)) }
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : ordered(lhs.item, rhs.item)
            }
        return Array(scored.prefix(limit).map(\.item))
    }

    /// An item's relevance for a query: the sum over needles of the best field a
    /// needle hits, so matching every needle in the title outranks matching them
    /// scattered across URLs or notes.
    private static func score(_ entry: Entry, needles: [String]) -> Int {
        needles.reduce(0) { total, needle in total + fieldScore(entry, needle) }
    }

    private static func fieldScore(_ entry: Entry, _ needle: String) -> Int {
        if entry.title == needle { return 120 }
        if entry.title.hasPrefix(needle) { return 100 }
        if entry.title.contains(" " + needle) { return 80 }
        if entry.title.contains(needle) { return 60 }
        if entry.account.hasPrefix(needle) { return 45 }
        if entry.account.contains(needle) { return 30 }
        // It passed the filter, so it matched somewhere (a URL, note or custom field).
        return 10
    }

    /// Ordering for results. When `prioritizeUsage` is on, the most-used items
    /// lead, with the chosen order breaking ties (and ordering the long tail of
    /// never-used items, which all sit at zero). `lastModified` is most-recent-
    /// first, like Proton's "recent" sort; ties (and the alphabetical order) use
    /// the title.
    private func areInOrder(_ order: SortOrder, prioritizeUsage: Bool) -> (ItemSummary, ItemSummary) -> Bool {
        { [usage] lhs, rhs in
            if prioritizeUsage {
                let lhsUses = usage[lhs.id] ?? 0
                let rhsUses = usage[rhs.id] ?? 0
                if lhsUses != rhsUses { return lhsUses > rhsUses }
            }
            if order == .lastModified, lhs.modifyTime != rhs.modifyTime {
                return lhs.modifyTime > rhs.modifyTime
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// The fields Proton Pass searches for a login, joined into one normalized
    /// string. A needle never contains a space (the query is split on spaces),
    /// so a single space-joined blob matches the same as testing each field.
    private static func searchableText(for item: ItemSummary) -> String {
        var parts = [item.title]
        item.username.map { parts.append($0) }
        item.email.map { parts.append($0) }
        parts.append(contentsOf: item.urls)
        item.note.map { parts.append($0) }
        parts.append(contentsOf: item.customFields)
        return normalize(parts.joined(separator: " "))
    }

    private static func needles(from query: String) -> [String] {
        let tokens = normalize(query).split(separator: " ").map(String.init)
        return Array(Set(tokens))
    }

    /// lowercase, trim, then strip diacritics via NFD decomposition, matching
    /// Proton's `normalize(value, true)`.
    static func normalize(_ value: String) -> String {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = lowered.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !(0x0300...0x036F ~= $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }
}
