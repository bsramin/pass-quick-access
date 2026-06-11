// SPDX-License-Identifier: GPL-3.0-only

import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingKey.loadWebsiteIcons) private var loadWebsiteIcons = false
    @AppStorage(SettingKey.requireAuth) private var requireAuth = false
    @AppStorage(SettingKey.authTimeout) private var authTimeout = AuthTimeout.fiveMinutes.rawValue
    @AppStorage(SettingKey.sortOrder) private var sortOrder = SortOrder.lastModified.rawValue
    @State private var confirmingIcons = false
    @State private var showingIconHelp = false
    @State private var revertingAuth = false

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Open Quick Access", name: .toggleQuickAccess)
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("⌘Space is reserved by Spotlight, so pick any free combination. It works from any app.")
            }

            Section {
                Picker("Order results by", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } header: {
                Text("Sorting")
            } footer: {
                Text("pass-cli doesn't expose last-use time, so \u{201C}Recently modified\u{201D} sorts by edit date.")
            }

            Section {
                Toggle("Require Touch ID to open", isOn: $requireAuth)
                if requireAuth {
                    Picker("Ask again", selection: $authTimeout) {
                        ForEach(AuthTimeout.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
            } header: {
                Text("Security")
            } footer: {
                Text("Uses Touch ID, or your Mac password if Touch ID isn't available.")
            }

            Section {
                Toggle("Load icons from websites", isOn: $loadWebsiteIcons)
                Button("What does this share?") { showingIconHelp = true }
                    .buttonStyle(.link)
            } header: {
                Text("Website Icons")
            } footer: {
                Text("Off by default. Items use a locally generated monogram unless you turn this on.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .onChange(of: requireAuth) { previous, _ in
            if revertingAuth { revertingAuth = false; return }
            Task {
                let reason = previous ? "turn off the lock" : "turn on the lock"
                if await !BiometricAuth.authenticate(reason: reason) {
                    revertingAuth = true
                    requireAuth = previous
                }
            }
        }
        .onChange(of: loadWebsiteIcons) { _, isOn in
            if isOn { confirmingIcons = true }
        }
        .alert("Load icons from websites?", isPresented: $confirmingIcons) {
            Button("Cancel", role: .cancel) { loadWebsiteIcons = false }
            Button("Enable") {}
        } message: {
            Text(Self.privacyNotice)
        }
        .alert("Website icons & privacy", isPresented: $showingIconHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(Self.privacyHelp)
        }
    }

    private static let privacyNotice = """
    When enabled, the app requests a favicon directly from each website you have \
    a login for. Those sites, and anyone who can see your network traffic, can \
    record your IP address and infer that you hold an account with them. Icons are \
    cached locally and never uploaded anywhere.

    It also means the app reaches out to those sites as you browse, so requests \
    to many of your saved domains during a network check come from this setting.
    """

    private static let privacyHelp = """
    Icons are fetched straight from each site (https://<site>/favicon.ico). No \
    third-party icon service is used, so no single company receives the full list \
    of your accounts.

    The trade-off: each site you have a login for receives a request from your IP \
    when its icon loads, and anyone observing your network (ISP, network admin) can \
    see those same domains.

    Proton's own apps avoid this by loading icons through Proton's privacy proxy, \
    which this app cannot reach. While the setting is off, every item shows a \
    locally generated monogram and nothing leaves your Mac.

    For transparency: with this on, the app reaches out to the sites of the items \
    you browse. If you audit your network and see connections to many of your \
    saved domains, that traffic is this feature, not anything else. Local and \
    private addresses are never contacted.
    """
}
