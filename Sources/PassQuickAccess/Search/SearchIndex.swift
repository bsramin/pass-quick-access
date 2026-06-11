// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// In-memory search over the login index, reproducing Proton Pass's own matcher
/// (packages/pass/lib/search/match-items.ts): normalize, split the query into
/// space-separated needles, and keep items where every needle is a substring of
/// some searchable field. It is substring, not fuzzy, matching, with no scoring;
/// results keep the index order (alphabetical by title).
struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        let item: ItemSummary
        let searchable: String
    }

    private let entries: [Entry]

    /// True when items span more than one vault, so the UI should disambiguate
    /// results with a vault badge.
    let spansMultipleVaults: Bool

    init(items: [ItemSummary]) {
        entries = items.map { Entry(item: $0, searchable: Self.searchableText(for: $0)) }
        spansMultipleVaults = Set(items.map(\.vaultName)).count > 1
    }

    func search(_ rawQuery: String, sortOrder: SortOrder, limit: Int = 200) -> [ItemSummary] {
        let needles = Self.needles(from: rawQuery)
        let matched = needles.isEmpty
            ? entries.map(\.item)
            : entries.filter { entry in needles.allSatisfy(entry.searchable.contains) }.map(\.item)

        return Array(matched.sorted(by: Self.areInOrder(sortOrder)).prefix(limit))
    }

    /// Ordering for results. `lastModified` is most-recent-first, like Proton's
    /// "recent" sort; ties (and the alphabetical order) use the title.
    private static func areInOrder(_ order: SortOrder) -> (ItemSummary, ItemSummary) -> Bool {
        { lhs, rhs in
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
