// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: QuickAccessController?
    private var agentController: AgentProxyController?
    private var reconnector: PATReconnector?
    private var settingsWindowController: SettingsWindowController?
    private let updateController = UpdateController()
    private var sparkleUpdater: SparkleUpdater?
    private var updateObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The browser-tab suggestion defaults on; every other setting is happy
        // with its off/zero default, so only this one needs registering.
        UserDefaults.standard.register(defaults: [SettingKey.matchActiveTab: true])
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        installStatusItem()
        setUpUpdates()

        guard let executable = PassCLIClient.locateExecutable() else {
            presentMissingCLI()
            return
        }

        let client = PassCLIClient(executable: executable)
        let reconnector = PATReconnector(client: client)
        self.reconnector = reconnector

        let controller = QuickAccessController(client: client, executable: executable, reconnector: reconnector, updateController: updateController)
        controller.registerHotkey()
        controller.preloadIndexIfUnlocked()
        self.controller = controller

        let agent = AgentProxyController(executable: executable, reconnector: reconnector)
        self.agentController = agent
        controller.onSessionRestored = { [weak agent] in await agent?.recover() }
        if UserDefaults.standard.bool(forKey: SettingKey.sshAgentEnabled) {
            Task { await agent.start() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentController?.stop()
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusIcon(hasUpdate: false)
        rebuildStatusMenu(hasUpdate: false)
    }

    /// The menu-bar image. Normally the plain template key, which adapts to the
    /// menu-bar appearance; while an update waits it becomes the key with the
    /// update pill attached on its right, rendered to a coloured (non-template)
    /// image so the pill keeps its accent.
    private func applyStatusIcon(hasUpdate: Bool) {
        guard let button = statusItem?.button else { return }
        button.toolTip = hasUpdate ? "An update is available" : nil
        guard hasUpdate else {
            let key = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Pass Quick Access")
            key?.isTemplate = true
            button.image = key
            return
        }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let renderer = ImageRenderer(content: MenuBarIcon().environment(\.colorScheme, isDark ? .dark : .light))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = false
        button.image = image
    }

    /// Rebuilds the status menu. "Update Now…" is only present while an update is
    /// waiting; "Check for Updates" is always there so the user can poll on demand.
    private func rebuildStatusMenu(hasUpdate: Bool) {
        let menu = NSMenu()

        if hasUpdate {
            let update = NSMenuItem(title: "Update Now…", action: #selector(openUpdateNotes), keyEquivalent: "")
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(update)
            menu.addItem(.separator())
        }

        let open = NSMenuItem(title: "Open Quick Access", action: #selector(openQuickAccess), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        open.setShortcut(for: .toggleQuickAccess)
        menu.addItem(open)

        let refresh = NSMenuItem(title: "Refresh Index", action: #selector(refreshIndex), keyEquivalent: "")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        let check = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(check)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    /// Reflects an available update (or its absence) onto the menu-bar icon and
    /// menu. `PQA_MOCK_UPDATE=1` injects a sample so the surface can be seen in
    /// development without a real appcast.
    private func setUpUpdates() {
        updateObserver = updateController.$available.sink { [weak self] update in
            DispatchQueue.main.async { self?.reflectUpdateState(update) }
        }
        // The mock lights up the pills with sample notes and skips Sparkle, so the
        // surface can be seen in development without a real appcast. Debug only, so
        // a release build can never surface a fake update.
        #if DEBUG
        if ProcessInfo.processInfo.environment["PQA_MOCK_UPDATE"] == "1" {
            updateController.present(AvailableUpdate(version: "2026-06-20.1", releaseNotes: Self.mockReleaseNotes))
            return
        }
        #endif
        let updater = SparkleUpdater(controller: updateController)
        sparkleUpdater = updater
        updater.start()
    }

    private func reflectUpdateState(_ update: AvailableUpdate?) {
        applyStatusIcon(hasUpdate: update != nil)
        rebuildStatusMenu(hasUpdate: update != nil)
    }

    @objc private func openUpdateNotes() {
        updateController.showReleaseNotes()
    }

    @objc private func checkForUpdates() {
        updateController.checkForUpdates()
    }

    /// Sample release notes used only by the `PQA_MOCK_UPDATE` development build.
    private static let mockReleaseNotes = """
    Pass Quick Access 2026-06-20.1

    Fixed
    - Stop the Proton Pass session from dropping on its own when the panel
      indexes several vaults at once.
    - Keep the SSH agent working after a session refresh, without having to
      toggle it off and on in Settings.

    Changed
    - Show vault items as they load instead of waiting for the whole index, so
      the panel is usable straight away.
    """

    /// An accessory app has no menu bar, but text-editing shortcuts (⌘A, ⌘V,
    /// ⌘X) are routed through the main menu's Edit items, so without one they
    /// never reach the search field's field editor. Copy (⌘C) is left out on
    /// purpose: in the quick-access panel that shortcut copies the selected
    /// item's password instead of the search text.
    private func installMainMenu() {
        // The app menu carries Settings (⌘,) so the shortcut works whenever a
        // window is key; an item only in the status-bar menu wouldn't.
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func openQuickAccess() {
        controller?.show()
    }

    @objc private func refreshIndex() {
        controller?.refreshIndex()
    }

    @objc private func openSettings() {
        let controller = settingsWindowController
            ?? SettingsWindowController(agentController: agentController, reconnector: reconnector)
        settingsWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private func presentMissingCLI() {
        let alert = NSAlert()
        alert.messageText = "Proton Pass CLI not found"
        alert.informativeText = "Install pass-cli and sign in (pass-cli login), then relaunch."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
