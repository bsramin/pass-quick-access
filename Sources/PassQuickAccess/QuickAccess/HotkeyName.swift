// SPDX-License-Identifier: GPL-3.0-only

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleQuickAccess = Self(
        "toggleQuickAccess",
        default: .init(.space, modifiers: [.option, .shift])
    )
}
