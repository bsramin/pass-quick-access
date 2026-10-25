// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

/// Reading the version out of `pass-cli --version` and deciding whether it is
/// one this app can drive. The app carries no compatibility branches for older
/// CLIs, so this is the one place that knows what "too old" means.
final class PassCLIVersionTests: XCTestCase {
    func testItReadsTheVersionTheCLIPrints() {
        let version = PassCLIVersion("Proton Pass CLI 2.5.1 (84186e7)")

        XCTAssertEqual(version, PassCLIVersion(major: 2, minor: 5, patch: 1))
    }

    func testABuildHashIsNotRequired() {
        XCTAssertEqual(PassCLIVersion("Proton Pass CLI 2.5.1"), PassCLIVersion(major: 2, minor: 5, patch: 1))
    }

    func testVersionsCompareByNumberNotByText() {
        // "2.10.0" sorts before "2.9.0" as text, which would read a newer CLI as
        // an older one and send the user off to update something current.
        XCTAssertGreaterThan(PassCLIVersion(major: 2, minor: 10, patch: 0), PassCLIVersion(major: 2, minor: 9, patch: 0))
        XCTAssertGreaterThan(PassCLIVersion(major: 3, minor: 0, patch: 0), PassCLIVersion(major: 2, minor: 99, patch: 9))
        XCTAssertGreaterThan(PassCLIVersion(major: 2, minor: 5, patch: 2), PassCLIVersion(major: 2, minor: 5, patch: 1))
    }

    func testTheVersionTheAppWasBuiltAgainstIsSupported() {
        XCTAssertFalse(PassCLIVersion.isTooOld("Proton Pass CLI 2.5.1 (84186e7)"))
        XCTAssertFalse(PassCLIVersion.isTooOld("Proton Pass CLI 2.5.0"))
    }

    func testAnOlderCLIIsTooOld() {
        XCTAssertTrue(PassCLIVersion.isTooOld("Proton Pass CLI 2.4.1 (04de99b)"))
        XCTAssertTrue(PassCLIVersion.isTooOld("Proton Pass CLI 1.9.9"))
    }

    func testANewerCLIIsLeftAlone() {
        XCTAssertFalse(PassCLIVersion.isTooOld("Proton Pass CLI 3.0.0"))
    }

    func testAnUnreadableVersionIsNeverCalledTooOld() {
        // The prompt has to be wrong in the harmless direction: a CLI whose
        // version line we cannot parse still gets to run, and fails on its own
        // terms if it really is incompatible. Blocking here would turn a change
        // in the version banner into an app that refuses to start.
        XCTAssertFalse(PassCLIVersion.isTooOld("pass-cli nightly"))
        XCTAssertFalse(PassCLIVersion.isTooOld(""))
        XCTAssertNil(PassCLIVersion("Proton Pass CLI"))
    }
}
