// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// The preferences window, built on an `NSToolbar` in the preference style so it
/// gets the native System-Settings chrome: a centred title above a row of icon
/// tabs, with no separator line. Selecting a tab swaps the hosted SwiftUI pane and
/// sizes the window to that pane's height, holding the top-left corner so the
/// window grows or shrinks downward instead of jumping.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let agentController: AgentProxyController?
    private let reconnector: PATReconnector?
    /// One hosting controller for the window's life; its `rootView` is swapped per
    /// pane. `sizingOptions` is empty so it never drives the window size; the frame
    /// is set from the pane's declared height.
    private let hosting = NSHostingController(rootView: AnyView(EmptyView()))
    /// The dismissable sponsor link in the title bar, kept so it can be removed.
    private var sponsorBanner: NSTitlebarAccessoryViewController?
    /// Set while opening the About pane from the sponsor link, so its support
    /// block briefly highlights.
    private var highlightSponsorOnAbout = false

    private static let width: CGFloat = 520

    init(agentController: AgentProxyController?, reconnector: PATReconnector?) {
        self.agentController = agentController
        self.reconnector = reconnector

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: SettingsPane.general.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        super.init(window: window)

        hosting.sizingOptions = []
        window.contentViewController = hosting

        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        apply(.general)
        if !UserDefaults.standard.bool(forKey: SettingKey.sponsorBannerDismissed) {
            addSponsorBanner(to: window)
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows a pane: updates the title and hosted view, sizes the content to the
    /// pane's height, and pins the top-left corner so the window doesn't jump.
    private func apply(_ pane: SettingsPane) {
        guard let window else { return }
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.title = pane.title
        hosting.rootView = AnyView(paneView(pane))
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        window.setContentSize(NSSize(width: Self.width, height: pane.height))
        window.setFrameTopLeftPoint(topLeft)
    }

    @objc private func paneSelected(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        apply(pane)
    }

    /// Adds the sponsor link as a thin full-width strip just below the toolbar,
    /// link right-aligned. A trailing title-bar accessory would collide with the
    /// centred preference toolbar, so this sits on its own row instead.
    private func addSponsorBanner(to window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        let host = NSHostingView(rootView: SponsorBanner(
            onSupport: { [weak self] in self?.openSponsor() },
            onDismiss: { [weak self] in self?.dismissSponsorBanner() }
        ))
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: 30)
        accessory.view = host
        window.addTitlebarAccessoryViewController(accessory)
        sponsorBanner = accessory
    }

    /// Opens the About pane with its support block highlighted, then retires the
    /// link (it's a one-time nudge).
    private func openSponsor() {
        highlightSponsorOnAbout = true
        apply(.about)
        highlightSponsorOnAbout = false
        dismissSponsorBanner()
    }

    /// Removes the link and remembers it, so it doesn't return.
    private func dismissSponsorBanner() {
        if let window, let banner = sponsorBanner,
           let index = window.titlebarAccessoryViewControllers.firstIndex(of: banner) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        sponsorBanner = nil
        UserDefaults.standard.set(true, forKey: SettingKey.sponsorBannerDismissed)
    }

    private func paneView(_ pane: SettingsPane) -> some View {
        let content: AnyView
        switch pane {
        case .general: content = AnyView(GeneralSettings())
        case .autofill: content = AnyView(AutofillSettings())
        case .security: content = AnyView(SecuritySettings())
        case .icons: content = AnyView(IconSettings())
        case .account: content = AnyView(AccountSettingsView(reconnector: reconnector))
        case .ssh: content = AnyView(sshView)
        case .about: content = AnyView(AboutSettings(highlightSponsor: highlightSponsorOnAbout))
        }
        return content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var sshView: some View {
        if let agentController {
            SSHSettingsView(controller: agentController)
        } else {
            ContentUnavailableView(
                "pass-cli not found",
                systemImage: "key.horizontal",
                description: Text("Install pass-cli and relaunch to use the SSH agent.")
            )
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.icon, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(paneSelected(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}
