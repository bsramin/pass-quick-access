// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

/// Records how often the prompt was shown and answers with a scripted result.
private actor FakePresenter: SignApprovalPresenting {
    private(set) var presentations = 0
    private let approve: Bool

    init(approve: Bool) { self.approve = approve }

    func present(_ request: SignRequest) async -> Bool {
        presentations += 1
        return approve
    }

    func count() -> Int { presentations }
}

final class SignAuthorizerTests: XCTestCase {
    private func tempStore() -> RememberedDecisionsStore {
        RememberedDecisionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pqa-auth-\(UUID().uuidString).json"))
    }

    private func request(
        identity: String?, fingerprint: String = "abc123", batchMode: Bool = false
    ) -> SignRequest {
        SignRequest(
            client: RequestingProgram(name: "git", command: "git push", showCommand: true, batchMode: batchMode),
            peer: VerifiedPeer(identity: identity),
            fingerprint: fingerprint,
            keyName: "Personal key"
        )
    }

    private func authorizer(
        store: RememberedDecisionsStore, presenter: SignApprovalPresenting, remember: Bool = false
    ) -> SignAuthorizer {
        SignAuthorizer(store: store, presenter: presenter, rememberApprovedApps: { remember })
    }

    func testBatchModeIsDeniedWithoutPrompting() async {
        let presenter = FakePresenter(approve: true)
        let authorizer = authorizer(store: tempStore(), presenter: presenter)
        let allowed = await authorizer.authorize(request(identity: "git", batchMode: true))
        XCTAssertFalse(allowed)
        let count = await presenter.count()
        XCTAssertEqual(count, 0)
    }

    func testRememberedAllowShortCircuitsThePrompt() async {
        let store = tempStore()
        await store.remember(RememberedSignDecision(
            identity: "git", appName: "git", fingerprint: nil, keyName: nil, allow: true, createdAt: Date()
        ))
        let presenter = FakePresenter(approve: false)
        let authorizer = authorizer(store: store, presenter: presenter)
        let allowed = await authorizer.authorize(request(identity: "git"))
        XCTAssertTrue(allowed)
        let count = await presenter.count()
        XCTAssertEqual(count, 0)
    }

    func testApprovedVerifiedPeerIsCachedForTheSession() async {
        let presenter = FakePresenter(approve: true)
        let authorizer = authorizer(store: tempStore(), presenter: presenter)
        let first = await authorizer.authorize(request(identity: "git"))
        let second = await authorizer.authorize(request(identity: "git"))
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        let count = await presenter.count()
        XCTAssertEqual(count, 1, "second request should ride the session cache")
    }

    func testUnverifiedPeerNeverRidesTheCache() async {
        let presenter = FakePresenter(approve: true)
        let authorizer = authorizer(store: tempStore(), presenter: presenter)
        _ = await authorizer.authorize(request(identity: nil))
        _ = await authorizer.authorize(request(identity: nil))
        let count = await presenter.count()
        XCTAssertEqual(count, 2, "an unverifiable peer must be prompted every time")
    }

    func testApprovalIsRememberedWhenThePolicyIsOn() async {
        let store = tempStore()
        let authorizer = authorizer(store: store, presenter: FakePresenter(approve: true), remember: true)
        _ = await authorizer.authorize(request(identity: "git"))
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.identity, "git")
        XCTAssertNil(all.first?.fingerprint, "a trusted app applies to any key")
    }

    func testApprovalIsNotRememberedWhenThePolicyIsOff() async {
        let store = tempStore()
        let authorizer = authorizer(store: store, presenter: FakePresenter(approve: true), remember: false)
        _ = await authorizer.authorize(request(identity: "git"))
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }
}
