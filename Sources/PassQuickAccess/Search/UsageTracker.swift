// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Records how often each item is used, so the list can lead with the logins the
/// user actually reaches for. Counts are keyed by item id (`shareID/itemID`) and
/// kept in `UserDefaults`: they're not secret (an id and a tally) and need to
/// outlive a relaunch. A "use" is any action that pulls a credential, a fill, a
/// copy, or opening the site.
@MainActor
final class UsageTracker {
    private let defaults: UserDefaults
    private let key = "itemUsageCounts"
    private var counts: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        counts = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    /// Whether usage is being remembered at all. Off by default, so without the
    /// opt-in nothing is recorded and the list keeps its plain order.
    var isEnabled: Bool { defaults.bool(forKey: SettingKey.prioritizeFrequentlyUsed) }

    /// A snapshot for ranking, handed to the search index when it's built.
    var snapshot: [String: Int] { counts }

    /// Records one use of an item and persists the new tally. A no-op while the
    /// opt-in is off, so usage is only ever stored when the user asked for it.
    func record(_ id: String) {
        guard isEnabled else { return }
        counts[id, default: 0] += 1
        defaults.set(counts, forKey: key)
    }

    /// Drops tallies for items no longer in the index (deleted logins), so the
    /// store doesn't accumulate ids forever. Called after a full index.
    func prune(keeping ids: Set<String>) {
        let filtered = counts.filter { ids.contains($0.key) }
        guard filtered.count != counts.count else { return }
        counts = filtered
        defaults.set(counts, forKey: key)
    }
}
