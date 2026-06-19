// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

final class ReleaseVersionTests: XCTestCase {
    func testFormatsADatedBuildAsItsReleaseTag() {
        XCTAssertEqual(ReleaseVersion.display("20260619.3"), "2026-06-19.3")
        XCTAssertEqual(ReleaseVersion.display("20260101.10"), "2026-01-01.10")
    }

    func testLeavesANonDatedBuildAlone() {
        XCTAssertEqual(ReleaseVersion.display("1"), "1")
        XCTAssertEqual(ReleaseVersion.display(""), "")
        XCTAssertEqual(ReleaseVersion.display("2026061.3"), "2026061.3")
    }
}
