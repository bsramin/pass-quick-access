// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// A non-activating, borderless floating panel: it can take keyboard focus for
/// the search field without pulling the user out of the app they were in, and
/// it carries no title bar, so its height matches the content exactly. Rounded
/// corners are drawn by the SwiftUI content; the window stays clear behind them.
final class QuickAccessPanel: NSPanel {
    /// Called when the panel stops being the key window, so the controller can
    /// dismiss it the moment focus moves elsewhere.
    var onResignKey: (@MainActor () -> Void)?

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 52),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        // No appear animation: the panel should snap in at its final size rather
        // than scale up from a larger frame for a moment.
        animationBehavior = .none

        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if let onResignKey {
            MainActor.assumeIsolated { onResignKey() }
        }
    }
}
