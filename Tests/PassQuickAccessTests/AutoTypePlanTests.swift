// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

final class AutoTypePlanTests: XCTestCase {
    func testLoginTypesUsernameTabThenPassword() {
        XCTAssertEqual(
            AutoTypePlan.login(username: "ada", submit: false),
            [.text("ada"), .tab, .secret]
        )
    }

    func testLoginSubmitsWhenAsked() {
        XCTAssertEqual(
            AutoTypePlan.login(username: "ada", submit: true),
            [.text("ada"), .tab, .secret, .return]
        )
    }

    func testUsernameOnlyIsJustTheUsername() {
        XCTAssertEqual(AutoTypePlan.username("ada"), [.text("ada")])
    }

    func testPasswordOnlyOptionallySubmits() {
        XCTAssertEqual(AutoTypePlan.password(submit: false), [.secret])
        XCTAssertEqual(AutoTypePlan.password(submit: true), [.secret, .return])
    }

    func testCodeOptionallySubmits() {
        XCTAssertEqual(AutoTypePlan.code(submit: false), [.code])
        XCTAssertEqual(AutoTypePlan.code(submit: true), [.code, .return])
    }

    /// The plan must reference secrets by role, never carry their value: the only
    /// literal text in a login is the username, and the password/code are markers
    /// resolved later. This keeps the secret out of anything that holds a plan.
    func testSecretsAreNeverEmbeddedAsText() {
        let literals = AutoTypePlan.login(username: "ada", submit: true).compactMap { step -> String? in
            if case .text(let value) = step { return value }
            return nil
        }
        XCTAssertEqual(literals, ["ada"])

        XCTAssertFalse(AutoTypePlan.password(submit: false).contains { step in
            if case .text = step { return true }
            return false
        })
    }
}
