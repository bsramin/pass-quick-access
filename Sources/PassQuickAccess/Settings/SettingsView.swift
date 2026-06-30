// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import KeyboardShortcuts
import SwiftUI

/// One preferences pane: its toolbar title, icon, and the height the window
/// takes while it's shown. The window chrome is an `NSToolbar` in the preference
/// style, set up in `SettingsWindowController`.
enum SettingsPane: String, CaseIterable {
    case general, autofill, security, icons, account, ssh, about

    var title: String {
        switch self {
        case .general: return "General"
        case .autofill: return "Autofill"
        case .security: return "Security"
        case .icons: return "Icons"
        case .account: return "Account"
        case .ssh: return "SSH Agent"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .autofill: return "keyboard"
        case .security: return "lock"
        case .icons: return "photo"
        case .account: return "person.crop.circle"
        case .ssh: return "key.horizontal"
        case .about: return "info.circle"
        }
    }

    /// The content height the window takes for this pane, sized to fit its tallest
    /// block so nothing scrolls. Sub-tabbed panes stay short by showing one block.
    var height: CGFloat {
        switch self {
        case .general: return 380
        case .autofill: return 260
        case .security: return 210
        case .icons: return 190
        case .account: return 290
        case .ssh: return 320
        case .about: return 380
        }
    }
}

/// A segmented control that splits a pane into blocks: a rounded track with the
/// selected block highlighted, clearly readable as the sub-navigation.
struct SubTabBar<Tab: Identifiable & Equatable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    Text(title(tab))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.accentColor : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }
}


/// The activation hotkey and how results are ordered.
struct GeneralSettings: View {
    @AppStorage(SettingKey.sortOrder) private var sortOrder = SortOrder.lastModified.rawValue
    @AppStorage(SettingKey.prioritizeFrequentlyUsed) private var prioritizeFrequentlyUsed = false

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
                Toggle("Show frequently used items first", isOn: $prioritizeFrequentlyUsed)
            } header: {
                Text("Sorting")
            } footer: {
                Text("pass-cli doesn't expose last-use time, so \u{201C}Recently modified\u{201D} sorts by edit date. [Ask Proton to add it.](https://protonmail.uservoice.com/forums/953584-proton-pass-authenticator/suggestions/51396523-cli-expose-and-update-last-used-time-for-items)\n\nShowing frequently used items first keeps a private tally, on this Mac, of how often you use each login and floats your most-used ones to the top. Off by default; nothing about usage is stored unless you turn it on.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Using a saved login: whether picking an item fills or copies, the access fill
/// needs, and matching the item to the page open in the browser. Split into sub-
/// tabs since it covers three distinct blocks.
struct AutofillSettings: View {
    enum Block: String, CaseIterable, Identifiable {
        case action, filling, browser
        var id: String { rawValue }
        var title: String {
            switch self {
            case .action: return "Action"
            case .filling: return "Filling"
            case .browser: return "Browser Match"
            }
        }
    }

    @AppStorage(SettingKey.actionMode) private var actionMode = ActionMode.fillAndCopy.rawValue
    @AppStorage(SettingKey.autotypeSubmitOnFill) private var submitOnFill = false
    @AppStorage(SettingKey.matchActiveTab) private var matchActiveTab = true
    @AppStorage(SettingKey.firefoxAccessibility) private var firefoxAccessibility = false
    @AppStorage(SettingKey.webAppMatching) private var webAppMatching = false
    @State private var block: Block = .action
    @State private var accessibilityTrusted = AutoTyper.isProcessTrusted

    var body: some View {
        VStack(spacing: 0) {
            SubTabBar(selection: $block, tabs: blocks, title: \.title)
            Form {
                switch block {
                case .action: action
                case .filling: filling
                case .browser: browser
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: actionMode) { _, _ in
            if !blocks.contains(block) { block = .action }
        }
        .task {
            // Reflect the access state the moment it's granted in System Settings,
            // without reopening this window.
            while !Task.isCancelled {
                accessibilityTrusted = AutoTyper.isProcessTrusted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Filling has nothing to show in copy-only mode, so it drops out.
    private var blocks: [Block] {
        actionMode == ActionMode.copyOnly.rawValue ? [.action, .browser] : Block.allCases
    }

    @ViewBuilder
    private var action: some View {
        Section {
            Picker("When you pick an item", selection: $actionMode) {
                ForEach(ActionMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } footer: {
            Text("Fill types the login into the app you came from; copy puts it on the clipboard.")
        }
    }

    @ViewBuilder
    private var filling: some View {
        Section {
            LabeledContent("Accessibility access") {
                if accessibilityTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Open System Settings…") { AutoTyper.openAccessibilitySettings() }
                }
            }
            Toggle("Press Return after filling", isOn: $submitOnFill)
        } footer: {
            Text("Fill needs macOS Accessibility access to send the keystrokes. \u{201C}Press Return\u{201D} also submits the form, which not every site expects.")
        }
    }

    @ViewBuilder
    private var browser: some View {
        Section {
            Toggle("Suggest the item for the open tab", isOn: $matchActiveTab)
            if matchActiveTab {
                Toggle("Include Firefox and Zen", isOn: $firefoxAccessibility)
                Toggle("Include web apps (Safari and Electron)", isOn: $webAppMatching)
            }
        } footer: {
            Text("Opening the panel over a browser selects the item for the page. Safari and Chromium read the address over Automation. Firefox, Zen and web apps expose none, so matching them turns on their accessibility engine, a small cost; many web apps also have no matchable URL.")
        }
    }
}

/// The Touch ID lock on opening the panel.
struct SecuritySettings: View {
    @AppStorage(SettingKey.requireAuth) private var requireAuth = false
    @AppStorage(SettingKey.authTimeout) private var authTimeout = AuthTimeout.fiveMinutes.rawValue
    @State private var revertingAuth = false

    var body: some View {
        Form {
            Section {
                Toggle("Require Touch ID to open", isOn: $requireAuth)
                if requireAuth {
                    Picker("Ask again", selection: $authTimeout) {
                        ForEach(AuthTimeout.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
            } header: {
                Text("Lock")
            } footer: {
                Text("Uses Touch ID, or your Mac password if Touch ID isn't available.")
            }
        }
        .formStyle(.grouped)
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
    }
}

/// Whether to fetch website favicons, with the privacy trade-off spelled out.
struct IconSettings: View {
    @AppStorage(SettingKey.loadWebsiteIcons) private var loadWebsiteIcons = false
    @State private var confirmingIcons = false
    @State private var showingIconHelp = false

    var body: some View {
        Form {
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
        .onChange(of: loadWebsiteIcons) { _, isOn in
            if isOn { confirmingIcons = true }
        }
        .alert("Load icons from websites?", isPresented: $confirmingIcons) {
            Button("Cancel", role: .cancel) { loadWebsiteIcons = false }
            Button("Enable") {}
        } message: {
            Text(Self.privacyNotice)
        }
        .sheet(isPresented: $showingIconHelp) {
            IconHelp(text: Self.privacyHelp) { showingIconHelp = false }
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

/// The website-icons privacy explanation, shown as a sheet to match the token
/// help rather than a cramped alert.
private struct IconHelp: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Website icons & privacy").font(.headline)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// The app's identity, version, links, and the support block (which can be
/// briefly highlighted when arrived at from the sponsor link).
struct AboutSettings: View {
    var highlightSponsor = false
    @State private var highlight = false

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Pass Quick Access")
                .font(.system(size: 16, weight: .semibold))
            Text(Self.version)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("A native quick-access panel for Proton Pass.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://bsramin.github.io/pass-quick-access")!)
                Link("GitHub", destination: URL(string: "https://github.com/bsramin/pass-quick-access")!)
                Link("License", destination: URL(string: "https://github.com/bsramin/pass-quick-access/blob/main/LICENSE")!)
            }
            .font(.system(size: 12))
            .padding(.top, 4)

            VStack(spacing: 8) {
                Text("Free and open source. A sponsor would cover its Apple Developer membership; a Proton referral helps too, and gets you two weeks of a paid plan.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    Link("Sponsor on GitHub", destination: URL(string: "https://github.com/sponsors/bsramin")!)
                    Link("Proton referral", destination: URL(string: "https://pr.tn/ref/H6KQSW71")!)
                }
                .font(.system(size: 12))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(highlight ? 0.16 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(highlight ? 0.55 : 0))
            )
            .padding(.top, 4)

            Spacer()
            Text("Released under the GNU General Public License v3.0.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .onAppear {
            guard highlightSponsor else { return }
            highlight = true
            withAnimation(.easeInOut(duration: 1.8).delay(0.4)) { highlight = false }
        }
    }

    private static var version: String {
        "Version \(ReleaseVersion.current)"
    }
}

/// The dismissable sponsor link, a thin strip below the toolbar: an ✕ to dismiss
/// and a link that opens the About pane on the sponsor block.
struct SponsorBanner: View {
    let onSupport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Hide this")

                Button(action: onSupport) {
                    Text("Support this project")
                        .font(.system(size: 12, weight: .medium))
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            Divider()
        }
    }
}
