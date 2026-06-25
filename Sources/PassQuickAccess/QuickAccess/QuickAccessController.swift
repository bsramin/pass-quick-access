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
    private let largeType = LargeTypeWindowController()
    private let autoTyper = AutoTyper()
    private let recovery: SessionRecovery
    private let reconnector: PATReconnector
    private let updateController: UpdateController
    private let webLogin: WebLogin
    private var panel: QuickAccessPanel?
    private var previousApp: NSRunningApplication?
    private var anchorTopLeft: NSPoint?
    private var cancellable: AnyCancellable?
    private var lastUnlock: Date?
    /// The app that was frontmost before a reveal, restored when the panel
    /// reappears after the large-type window closes.
    private var appBeforeLargeType: NSRunningApplication?

    /// Invoked after a signed-out session is restored, so the SSH agent can be
    /// brought back in step with the panel.
    var onSessionRestored: (() async -> Void)?

    private let panelWidth: CGFloat = 640

    init(client: PassCLIClient, executable: URL, reconnector: PATReconnector, updateController: UpdateController) {
        self.recovery = SessionRecovery(client: client)
        self.reconnector = reconnector
        self.updateController = updateController
        self.webLogin = WebLogin(executable: executable)
        viewModel = QuickAccessViewModel(client: client)
        viewModel.onDismiss = { [weak self] in self?.hide() }
        viewModel.onSignIn = { [weak self] in self?.beginSignIn() }
        viewModel.onReconnect = { [weak self] in self?.beginReconnect() }
        viewModel.onCancelRecovery = { [weak self] in
            self?.recovery.cancel()
            self?.webLogin.cancel()
        }
        viewModel.onAutotype = { [weak self] request in self?.autotype(request) }
        viewModel.onReveal = { [weak self] request in
            guard let self else { return }
            self.appBeforeLargeType = self.previousApp
            self.largeType.show(title: request.title, field: request.field, value: request.value)
        }
        reconnector.onReconnected = { [weak self] in await self?.handleSessionRestored() }
        largeType.onClose = { [weak self] in self?.reshowAfterLargeType() }
        cancellable = viewModel.objectWillChange.sink { [weak self] in
            // objectWillChange fires before the value updates; defer so the
            // height is computed from the new state.
            DispatchQueue.main.async { self?.layoutPanel() }
        }
        // Warm a Gecko browser's accessibility tree when it comes to the front, so
        // the tab URL is ready to read by the time the panel is summoned.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    @objc private func appActivated(_ note: Notification) {
        guard UserDefaults.standard.bool(forKey: SettingKey.matchActiveTab),
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              BrowserContext.isGecko(app.bundleIdentifier) else { return }
        BrowserContext.activateAccessibility(of: app)
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

    /// Starts the browser login and waits for the session to come back, then
    /// reloads the panel and recovers the agent. Driven from the signed-out
    /// prompt; the panel stays open showing progress while it waits.
    private func beginSignIn() {
        webLogin.start()
        recovery.waitForSession { [weak self] restored in
            guard let self else { return }
            Task { @MainActor in
                self.webLogin.cancel()
                if restored {
                    await self.handleSessionRestored()
                } else {
                    await self.viewModel.finishRecovery(succeeded: false)
                }
            }
        }
    }

    /// Reconnects with the stored access token: one Touch ID, then the session,
    /// panel and agent all come back. On failure the prompt is left in place.
    private func beginReconnect() {
        Task {
            let restored = await reconnector.reconnectInteractively(reason: "sign back in to Proton Pass")
            if !restored { await viewModel.finishRecovery(succeeded: false) }
        }
    }

    /// Shared completion for any successful re-login: reload the index and bring
    /// the SSH agent back in step.
    private func handleSessionRestored() async {
        await viewModel.finishRecovery(succeeded: true)
        await onSessionRestored?()
    }

    /// Brings the panel back on the same item after the large-type window closes,
    /// without re-authenticating (the session was just unlocked).
    private func reshowAfterLargeType() {
        present(frontmost: appBeforeLargeType ?? NSWorkspace.shared.frontmostApplication)
        appBeforeLargeType = nil
    }

    func show() {
        // Capture the target before anything (an auth sheet would change it).
        let frontmost = NSWorkspace.shared.frontmostApplication
        // Read the browser's tab now, while it's still frontmost, to pre-select
        // the matching item once the list is up.
        viewModel.contextHost = browserHost(of: frontmost)

        guard requiresUnlock else {
            present(frontmost: frontmost)
            return
        }
        Task {
            guard let auth = await BiometricAuth.authenticatedContext(reason: "unlock Pass Quick Access") else { return }
            lastUnlock = Date()
            present(frontmost: frontmost)
            // Reuse the unlock's Touch ID to restore a dropped session, so the
            // panel fills in instead of showing the signed-out prompt.
            await reconnector.reconnectIfNeeded(using: auth.context)
        }
    }

    private func present(frontmost: NSRunningApplication?) {
        previousApp = frontmost

        viewModel.prepareForShow()
        viewModel.canReconnect = PATStore.hasToken()

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

    /// The host of the frontmost browser's active tab, when the setting is on and
    /// the frontmost app is a scriptable browser. Nil otherwise.
    private func browserHost(of app: NSRunningApplication?) -> String? {
        guard UserDefaults.standard.bool(forKey: SettingKey.matchActiveTab), let app else { return nil }
        return BrowserContext.activeTabURL(of: app).flatMap(WebHost.from)
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

    /// Types a credential into the app that was frontmost when the panel opened.
    /// Without Accessibility access nothing can be posted, so it prompts and
    /// leaves the panel up with a hint rather than silently doing nothing.
    private func autotype(_ request: AutotypeRequest) {
        guard AutoTyper.isProcessTrusted else {
            // Drop the panel first: as a floating window it sits over the system
            // Accessibility prompt and hides it. Then ask for access and open the
            // settings pane so the grant is one visible step away.
            hide()
            AutoTyper.promptForAccess()
            AutoTyper.openAccessibilitySettings()
            return
        }
        guard let target = previousApp,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            viewModel.toast = "Couldn't find the app to fill"
            return
        }
        hide()
        Task {
            // Only type once the intended app is actually frontmost, so a secret
            // can never land in the wrong window if focus didn't return.
            guard await frontmost(is: target) else { return }
            autoTyper.type(request)
        }
    }

    /// Waits briefly for `app` to become the frontmost application after the
    /// panel hands focus back, polling so a slow activation still catches up.
    private func frontmost(is app: NSRunningApplication) async -> Bool {
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return true
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private func makePanel() -> QuickAccessPanel {
        let panel = QuickAccessPanel(contentView: makeContentView())
        panel.onResignKey = { [weak self] in self?.hide(restoringFocus: false) }
        return panel
    }

    private func makeContentView() -> NSView {
        NSHostingView(rootView: QuickAccessView(viewModel: viewModel, updateController: updateController))
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
                : viewModel.actionRows.count
            let count = CGFloat(max(rowCount, 1))
            let rows = count * 30 + (count - 1) * 2 + 16
            return searchField + 1 + header + 1 + rows + footer
        }

        let rowHeight: CGFloat = 48
        let listPadding: CGFloat = 16
        let visibleRows = min(viewModel.results.count, 8)
        guard visibleRows > 0 else {
            // Status states (signed-out, loading, no matches) show no footer.
            return searchField + 1 + QuickAccessView.statusAreaHeight
        }
        return searchField + 1 + CGFloat(visibleRows) * rowHeight + listPadding + footer
    }
}
