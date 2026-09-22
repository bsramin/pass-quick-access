// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import ServiceManagement

/// Whether the app starts itself when you log in.
///
/// It matters more than it looks. A menu-bar app that isn't running answers no
/// hotkey, serves no SSH signature, and, now, has no AutoFill to offer: the
/// extension is sandboxed and cannot read a vault on its own, so with the app
/// closed a password prompt has nothing behind it. Until this existed the README
/// told nobody to add the app by hand, and most people presumably never did.
///
/// macOS keeps the real state, not us: the user can revoke a login item in
/// System Settings without the app hearing about it, so the switch reads
/// `status` every time rather than trusting a stored flag.
@MainActor
enum LoginItem {
    enum State: Equatable {
        case on
        case off
        /// Registered, but the user has yet to allow it in System Settings.
        /// macOS shows its own prompt once; afterwards the only way through is
        /// the Login Items pane.
        case awaitingApproval
        /// No service to register, which is what a build running from a folder
        /// macOS doesn't consider an installed app looks like.
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .awaitingApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .off
        }
    }

    /// Returns whether it took. A failure is reported rather than swallowed
    /// because the switch has to end up showing what macOS actually thinks, not
    /// what the user asked for.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("Login item could not be \(enabled ? "registered" : "unregistered"): \(error)")
            return false
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
