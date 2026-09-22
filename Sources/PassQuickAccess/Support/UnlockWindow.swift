// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// How long ago the user last proved who they are, and whether that still counts.
///
/// One window covers every surface. The panel and the AutoFill extension both
/// gate on it, so unlocking to copy a password does not mean being asked again
/// a moment later to fill one, which is what a user reasonably expects from a
/// timeout they set once in Settings.
@MainActor
final class UnlockWindow {
    private var lastUnlock: Date?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the user has to authenticate before anything is read. With the
    /// lock off this is always false; with a timeout of zero, always true.
    var isRequired: Bool {
        guard defaults.bool(forKey: SettingKey.requireAuth) else { return false }
        let timeout = defaults.integer(forKey: SettingKey.authTimeout)
        guard timeout > 0, let lastUnlock else { return true }
        return Date().timeIntervalSince(lastUnlock) > Double(timeout)
    }

    func record() {
        lastUnlock = Date()
    }

    /// Drops the window, so the next request authenticates again.
    func clear() {
        lastUnlock = nil
    }
}
