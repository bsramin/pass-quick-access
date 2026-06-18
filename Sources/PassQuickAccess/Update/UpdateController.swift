// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Single source of truth for the "an update is available" state. The pills (in
/// the menu bar and the search bar) and the notes window all read from here, and
/// the Sparkle layer writes to it when a check turns one up. Keeping the UI
/// behind this object means the mock and the real updater drive exactly the same
/// surface.
@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var available: AvailableUpdate?

    /// Begins the install the user agreed to in the notes window. Set by the
    /// Sparkle layer; nil in a mock build, where the button just closes the window.
    var onInstall: (() -> Void)?
    /// Runs an on-demand appcast check from the "Check for Updates" menu item.
    /// Set by the Sparkle layer; nil in a mock build.
    var onCheck: (() -> Void)?

    private var notesWindow: NSWindow?

    /// Publishes an available update (or clears it), which lights up or hides the
    /// pills. Called by the Sparkle user driver.
    func present(_ update: AvailableUpdate?) {
        available = update
        if update == nil { notesWindow?.close() }
    }

    /// Opens the notes window, where the user can read what's new and start the
    /// update. Shared by both pills.
    func showReleaseNotes() {
        guard available != nil else { return }
        let window = notesWindow ?? makeWindow()
        notesWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The user chose to update now: start the install and close the window.
    func install() {
        notesWindow?.close()
        onInstall?()
    }

    /// The user chose to wait. Close the window but leave the pills up, so it
    /// stays a quiet, always-there reminder rather than nagging.
    func dismiss() {
        notesWindow?.close()
    }

    /// Runs an on-demand check from the "Check for Updates" menu item.
    func checkForUpdates() {
        onCheck?()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Software Update"
        window.contentView = NSHostingView(rootView: UpdateNotesView(controller: self))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
