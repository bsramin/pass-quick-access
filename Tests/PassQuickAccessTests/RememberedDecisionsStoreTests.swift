// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

final class RememberedDecisionsStoreTests: XCTestCase {
    private func tempStore() -> (RememberedDecisionsStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pqa-ssh-\(UUID().uuidString).json")
        return (RememberedDecisionsStore(fileURL: url), url)
    }

    private func decision(identity: String, fingerprint: String?, allow: Bool) -> RememberedSignDecision {
        RememberedSignDecision(
            identity: identity, appName: identity, fingerprint: fingerprint,
            keyName: fingerprint, allow: allow, createdAt: Date()
        )
    }

    func testRemembersAndReloadsFromDisk() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        await store.remember(decision(identity: "git", fingerprint: nil, allow: true))
        let reloaded = RememberedDecisionsStore(fileURL: url)
        let found = await reloaded.decision(identity: "git", fingerprint: "abc")
        XCTAssertEqual(found?.allow, true)
    }

    func testKeyScopedDecisionWinsOverAnyKey() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        await store.remember(decision(identity: "git", fingerprint: nil, allow: true))
        await store.remember(decision(identity: "git", fingerprint: "deadbeef", allow: false))

        let scoped = await store.decision(identity: "git", fingerprint: "deadbeef")
        XCTAssertEqual(scoped?.allow, false)
        let other = await store.decision(identity: "git", fingerprint: "feed")
        XCTAssertEqual(other?.allow, true)
    }

    func testForgetRemovesADecision() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = decision(identity: "tower", fingerprint: nil, allow: true)
        await store.remember(entry)
        await store.forget(id: entry.id)
        let found = await store.decision(identity: "tower", fingerprint: "x")
        XCTAssertNil(found)
    }
}
