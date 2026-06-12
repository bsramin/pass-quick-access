// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Persists the user's remembered "always allow / always deny" choices for the
/// SSH agent, so a trusted app doesn't prompt on every signature. Stored as JSON
/// under Application Support and loaded once on first use.
actor RememberedDecisionsStore {
    private let fileURL: URL
    private var cache: [RememberedSignDecision]?

    init(fileURL: URL = RememberedDecisionsStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PassQuickAccess", isDirectory: true)
            .appendingPathComponent("ssh-decisions.json")
    }

    /// The remembered decision governing this request, or `nil` if the user has
    /// never chosen to remember one. Key-scoped decisions win over "any key".
    func decision(identity: String, fingerprint: String) async -> RememberedSignDecision? {
        let all = load()
        return all.first { $0.identity == identity && $0.fingerprint == fingerprint }
            ?? all.first { $0.matches(identity: identity, fingerprint: fingerprint) }
    }

    func all() -> [RememberedSignDecision] {
        load().sorted { $0.createdAt > $1.createdAt }
    }

    /// Records a decision, replacing any existing one with the same scope.
    func remember(_ decision: RememberedSignDecision) {
        var all = load()
        all.removeAll { $0.identity == decision.identity && $0.fingerprint == decision.fingerprint }
        all.append(decision)
        persist(all)
    }

    func forget(id: String) {
        persist(load().filter { $0.id != id })
    }

    func forgetAll() {
        persist([])
    }

    private func load() -> [RememberedSignDecision] {
        if let cache { return cache }
        let decisions: [RememberedSignDecision]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([RememberedSignDecision].self, from: data) {
            decisions = decoded
        } else {
            decisions = []
        }
        cache = decisions
        return decisions
    }

    private func persist(_ decisions: [RememberedSignDecision]) {
        cache = decisions
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(decisions) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }
}
