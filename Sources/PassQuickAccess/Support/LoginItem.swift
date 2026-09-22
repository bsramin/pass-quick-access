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
    }

    /// `notFound` is folded into `off` rather than given a state of its own.
    /// Apple documents it as "no service to register", and an earlier version
    /// of this read that as "this copy can't be a login item" and greyed the
    /// switch out, on an app sitting in /Applications, registered, that
    /// registers perfectly well when actually asked. A status is not a
    /// permission: the way to find out whether registration works is to try it
    /// and report what comes back.
    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .awaitingApproval
        default: return .off
        }
    }

    /// Returns nil when it took, or something to show the user when it didn't.
    /// The switch has to end up showing what macOS thinks, not what was asked
    /// of it, so a failure is surfaced rather than swallowed.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // Already in the asked-for state is not a failure worth reporting;
            // the status read that follows will show it as done.
            if (error as NSError).code == kSMErrorAlreadyRegistered { return nil }
            return error.localizedDescription
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
