// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

final class FaviconHostTests: XCTestCase {
    func testLooksPublicAcceptsDomainsAndRejectsLocalLiterals() {
        XCTAssertTrue(FaviconHost.looksPublic("github.com"))
        XCTAssertTrue(FaviconHost.looksPublic("accounts.google.com"))

        // Local or private destinations a favicon must never reach.
        XCTAssertFalse(FaviconHost.looksPublic("localhost"))
        XCTAssertFalse(FaviconHost.looksPublic("printer.local"))
        XCTAssertFalse(FaviconHost.looksPublic("10.0.0.1"))
        XCTAssertFalse(FaviconHost.looksPublic("192.168.1.1"))
        XCTAssertFalse(FaviconHost.looksPublic("172.16.0.5"))
        XCTAssertFalse(FaviconHost.looksPublic("127.0.0.1"))
        XCTAssertFalse(FaviconHost.looksPublic("::1"))
    }
}
