// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Presents the large-type window. The value is held only by the live window and
/// dropped when it closes; nothing is logged or persisted. `onClose` fires when
/// the user dismisses it, so the caller can bring the panel back.
@MainActor
final class LargeTypeWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private var window: NSWindow?

    func show(title: String, field: String, value: String) {
        dropWindow()

        let hosting = NSHostingController(rootView: LargeTypeView(value: value))
        let window = LargeTypeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = title
        window.subtitle = field
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.setContentSize(hosting.view.fittingSize)
        window.center()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Removes the current window without notifying, used when replacing it.
    private func dropWindow() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window = nil
            onClose?()
        }
    }
}

/// A titled window that closes on Escape (which a plain `NSWindow` ignores).
private final class LargeTypeWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
