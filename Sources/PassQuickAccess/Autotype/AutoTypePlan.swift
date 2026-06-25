// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// One step in an autotype sequence. Secrets are referenced by role, never by
/// value: `.secret` and `.code` are filled in from the request at type time, so a
/// plan can be built, logged and tested without ever holding the password.
enum AutoTypeStep: Equatable, Sendable {
    /// A non-secret literal, such as the username.
    case text(String)
    /// The item's password, revealed only as it's posted.
    case secret
    /// The item's one-time code, revealed only as it's posted.
    case code
    case tab
    case `return`
}

/// Builds the keystroke sequences for the fill actions. Pure and side-effect
/// free so the ordering is unit-tested; the actual posting lives in `AutoTyper`.
enum AutoTypePlan {
    /// Username, then Tab to the password field, then the password. Optionally
    /// submits with Return. This is the common single-page login form.
    static func login(username: String, submit: Bool) -> [AutoTypeStep] {
        var steps: [AutoTypeStep] = [.text(username), .tab, .secret]
        if submit { steps.append(.return) }
        return steps
    }

    /// The username on its own, for the first page of a two-step login.
    static func username(_ username: String) -> [AutoTypeStep] {
        [.text(username)]
    }

    /// The password on its own, for the second page of a two-step login or a
    /// field that's already focused.
    static func password(submit: Bool) -> [AutoTypeStep] {
        submit ? [.secret, .return] : [.secret]
    }

    /// The one-time code, for a 2FA prompt.
    static func code(submit: Bool) -> [AutoTypeStep] {
        submit ? [.code, .return] : [.code]
    }
}

/// A resolved fill ready to type: the step sequence plus the secrets its
/// `.secret`/`.code` steps draw from. `Sendable` so it can cross to the
/// background thread that posts the events.
struct AutotypeRequest: Sendable {
    let steps: [AutoTypeStep]
    let secret: SensitiveString?
    let code: SensitiveString?

    init(steps: [AutoTypeStep], secret: SensitiveString? = nil, code: SensitiveString? = nil) {
        self.steps = steps
        self.secret = secret
        self.code = code
    }
}
