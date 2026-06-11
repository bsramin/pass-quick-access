// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

/// Owns the floating panel and wires it to the global hotkey. The panel grows
/// from a bare search field to fit its content, anchored by its top edge, and
/// can be gated behind Touch ID.
@MainActor
final class QuickAccessController {
    private let viewModel: QuickAccessViewModel
    private var panel: QuickAccessPanel?
    private var previousApp: NSRunningApplication?
    private var anchorTopLeft: NSPoint?
    private var cancellable: AnyCancellable?
    private var lastUnlock: Date?

    private let panelWidth: CGFloat = 640

    init(client: PassCLIClient) {
        viewModel = QuickAccessViewModel(client: client)
        viewModel.onDismiss = { [weak self] in self?.hide() }
        cancellable = viewModel.objectWillChange.sink { [weak self] in
            // objectWillChange fires before the value updates; defer so the
            // height is computed from the new state.
            DispatchQueue.main.async { self?.layoutPanel() }
        }
    }

    func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleQuickAccess) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
    }

    /// Warms the index at launch so the first open is instant. Skipped when the
    /// lock is on, so nothing is read before the user has authenticated; in that
    /// case the index loads right after the unlock instead.
    func preloadIndexIfUnlocked() {
        guard !UserDefaults.standard.bool(forKey: SettingKey.requireAuth) else { return }
        Task { await viewModel.loadIfNeeded() }
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        // Capture the target before anything (an auth sheet would change it).
        let frontmost = NSWorkspace.shared.frontmostApplication

        guard requiresUnlock else {
            present(frontmost: frontmost)
            return
        }
        Task {
            if await BiometricAuth.authenticate(reason: "unlock Pass Quick Access") {
                lastUnlock = Date()
                present(frontmost: frontmost)
            }
        }
    }

    private func present(frontmost: NSRunningApplication?) {
        previousApp = frontmost

        viewModel.prepareForShow()

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = makeContentView()

        anchorTopLeft = topLeftAnchor()
        layoutPanel()
        // Lay the content out at the final frame before showing, so the panel
        // never appears at the hosting view's larger fitting size for a frame.
        panel.contentView?.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        Task { await viewModel.loadIfNeeded() }
    }

    /// Whether the panel must authenticate before opening, given the setting and
    /// how long ago the last successful unlock was.
    private var requiresUnlock: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingKey.requireAuth) else { return false }
        let timeout = defaults.integer(forKey: SettingKey.authTimeout)
        guard timeout > 0, let lastUnlock else { return true }
        return Date().timeIntervalSince(lastUnlock) > Double(timeout)
    }

    /// Hides the panel. `restoringFocus` reactivates the app that was frontmost
    /// before the panel opened, which is right after a copy or escape but not
    /// when the user has clicked away to somewhere of their own choosing.
    func hide(restoringFocus: Bool = true) {
        guard panel?.isVisible == true else { return }
        viewModel.clearTransientSecrets()
        panel?.orderOut(nil)
        if restoringFocus { previousApp?.activate() }
        previousApp = nil
    }

    private func makePanel() -> QuickAccessPanel {
        let panel = QuickAccessPanel(contentView: makeContentView())
        panel.onResignKey = { [weak self] in self?.hide(restoringFocus: false) }
        return panel
    }

    private func makeContentView() -> NSView {
        NSHostingView(rootView: QuickAccessView(viewModel: viewModel))
    }

    /// The fixed top-left point the panel grows from, in the screen under the
    /// pointer, set high enough that an expanded list still has room below.
    private func topLeftAnchor() -> NSPoint? {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return nil }
        return NSPoint(x: visible.midX - panelWidth / 2, y: visible.maxY - visible.height * 0.16)
    }

    private func layoutPanel() {
        guard let panel, let anchor = anchorTopLeft else { return }
        let height = desiredHeight()
        panel.setFrame(
            NSRect(x: anchor.x, y: anchor.y - height, width: panelWidth, height: height),
            display: true
        )
    }

    private func desiredHeight() -> CGFloat {
        let searchField: CGFloat = 52
        guard viewModel.hasContent else { return searchField }

        let footer: CGFloat = 30
        if viewModel.isShowingDetail {
            let header: CGFloat = 52
            let rowCount = viewModel.isChoosingURL
                ? (viewModel.urlChoices?.count ?? 0)
                : viewModel.availableActions.count
            let count = CGFloat(max(rowCount, 1))
            let rows = count * 30 + (count - 1) * 2 + 16
            return searchField + 1 + header + 1 + rows + footer
        }

        let rowHeight: CGFloat = 48
        let listPadding: CGFloat = 16
        let visibleRows = min(viewModel.results.count, 8)
        let listHeight = visibleRows > 0
            ? CGFloat(visibleRows) * rowHeight + listPadding
            : QuickAccessView.statusAreaHeight
        return searchField + 1 + listHeight + footer
    }
}
