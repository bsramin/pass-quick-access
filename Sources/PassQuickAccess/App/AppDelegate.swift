// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: QuickAccessController?
    private var agentController: AgentProxyController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        installStatusItem()

        guard let executable = PassCLIClient.locateExecutable() else {
            presentMissingCLI()
            return
        }

        let controller = QuickAccessController(client: PassCLIClient(executable: executable))
        controller.registerHotkey()
        controller.preloadIndexIfUnlocked()
        self.controller = controller

        let agent = AgentProxyController(executable: executable)
        self.agentController = agent
        if UserDefaults.standard.bool(forKey: SettingKey.sshAgentEnabled) {
            Task { await agent.start() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentController?.stop()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Pass Quick Access")

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Quick Access", action: #selector(openQuickAccess), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        open.setShortcut(for: .toggleQuickAccess)
        menu.addItem(open)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

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

    @objc private func openSettings() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: SettingsView(agentController: agentController))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func presentMissingCLI() {
        let alert = NSAlert()
        alert.messageText = "Proton Pass CLI not found"
        alert.informativeText = "Install pass-cli and sign in (pass-cli login), then relaunch."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
