// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

/// Records how often the prompt was shown and answers with a scripted result.
/// The optional delay stands in for the time a real person takes to answer, so
/// concurrent requests genuinely overlap.
private actor FakePresenter: SignApprovalPresenting {
    private(set) var presentations = 0
    private let approve: Bool
    private let delay: Duration?

    init(approve: Bool, delay: Duration? = nil) {
        self.approve = approve
        self.delay = delay
    }

    func present(_ request: SignRequest) async -> Bool {
        presentations += 1
        if let delay { try? await Task.sleep(for: delay) }
        return approve
    }

    func count() -> Int { presentations }
}

/// A hand-wound clock, so the window can expire without the test waiting for it.
private final class Clock: @unchecked Sendable {
    private(set) var now = Date()

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

final class SignAuthorizerTests: XCTestCase {
    private func tempStore() -> RememberedDecisionsStore {
        RememberedDecisionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pqa-auth-\(UUID().uuidString).json"))
    }

    private func request(
        identity: String?, codeHash: String? = nil, fingerprint: String = "abc123", batchMode: Bool = false
    ) -> SignRequest {
        SignRequest(
            client: RequestingProgram(name: "git", command: "git push", showCommand: true, batchMode: batchMode),
            peer: VerifiedPeer(identity: identity, codeHash: codeHash),
            fingerprint: fingerprint,
            keyName: "Personal key"
        )
    }

    private func authorizer(
        store: RememberedDecisionsStore,
        presenter: SignApprovalPresenting,
        remember: Bool = false,
        window: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> SignAuthorizer {
        SignAuthorizer(
            store: store,
            presenter: presenter,
            rememberApprovedApps: { remember },
            window: { window },
            now: now
        )
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

    func testApprovedVerifiedPeerRidesTheWindow() async {
        let presenter = FakePresenter(approve: true)
        let authorizer = authorizer(store: tempStore(), presenter: presenter)
        let first = await authorizer.authorize(request(identity: "git"))
        let second = await authorizer.authorize(request(identity: "git"))
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        let count = await presenter.count()
        XCTAssertEqual(count, 1, "second request should ride the approval window")
    }

    func testTheWindowExpires() async {
        let presenter = FakePresenter(approve: true)
        let clock = Clock()
        let authorizer = authorizer(
            store: tempStore(), presenter: presenter, window: 300, now: { clock.now }
        )
        _ = await authorizer.authorize(request(identity: "git"))
        clock.advance(by: 301)
        _ = await authorizer.authorize(request(identity: "git"))
        let count = await presenter.count()
        XCTAssertEqual(count, 2, "an expired window must ask again")
    }

    func testAnotherKeyIsNotCoveredByTheWindow() async {
        let presenter = FakePresenter(approve: true)
        let authorizer = authorizer(store: tempStore(), presenter: presenter)
        _ = await authorizer.authorize(request(identity: "git", fingerprint: "aaa"))
        _ = await authorizer.authorize(request(identity: "git", fingerprint: "bbb"))
        let count = await presenter.count()
        XCTAssertEqual(count, 2, "the window is scoped to one key")
    }

    func testUnverifiedPeerRidesTheWindowOnItsCodeHash() async {
        let presenter = FakePresenter(approve: true)
        let authorizer = authorizer(store: tempStore(), presenter: presenter)
        _ = await authorizer.authorize(request(identity: nil, codeHash: "cafe"))
        _ = await authorizer.authorize(request(identity: nil, codeHash: "cafe"))
        _ = await authorizer.authorize(request(identity: nil, codeHash: "beef"))
        let count = await presenter.count()
        XCTAssertEqual(count, 2, "the window follows the exact binary")
    }

    func testPeerWithNothingToPinItIsAlwaysPrompted() async {
        let presenter = FakePresenter(approve: true)
        let authorizer = authorizer(store: tempStore(), presenter: presenter)
        _ = await authorizer.authorize(request(identity: nil))
        _ = await authorizer.authorize(request(identity: nil))
        let count = await presenter.count()
        XCTAssertEqual(count, 2, "a peer we can't pin at all must be prompted every time")
    }

    func testConcurrentRequestsShareOnePrompt() async {
        let presenter = FakePresenter(approve: true, delay: .milliseconds(120))
        let authorizer = authorizer(store: tempStore(), presenter: presenter)
        let pending = request(identity: "git")
        async let first = authorizer.authorize(pending)
        async let second = authorizer.authorize(pending)
        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
        let count = await presenter.count()
        XCTAssertEqual(count, 1, "one prompt should answer both")
    }

    func testUnverifiedPeerIsNeverRemembered() async {
        let store = tempStore()
        let authorizer = authorizer(
            store: store, presenter: FakePresenter(approve: true), remember: true
        )
        _ = await authorizer.authorize(request(identity: nil, codeHash: "cafe"))
        let all = await store.all()
        XCTAssertTrue(all.isEmpty, "only an anchored peer earns permanent trust")
    }

    func testApprovalIsRememberedWhenThePolicyIsOn() async {
        let store = tempStore()
        let authorizer = authorizer(store: store, presenter: FakePresenter(approve: true), remember: true)
        _ = await authorizer.authorize(request(identity: "git"))
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.identity, "git")
        XCTAssertEqual(all.first?.fingerprint, "abc123", "trust is scoped to the key that was approved")
    }

    func testApprovalIsNotRememberedWhenThePolicyIsOff() async {
        let store = tempStore()
        let authorizer = authorizer(store: store, presenter: FakePresenter(approve: true), remember: false)
        _ = await authorizer.authorize(request(identity: "git"))
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }
}
