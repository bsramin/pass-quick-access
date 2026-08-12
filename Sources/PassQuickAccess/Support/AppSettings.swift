// SPDX-License-Identifier: GPL-3.0-only

import Foundation

enum SettingKey {
    /// Opt-in: fetch each site's favicon for the result list. Off by default,
    /// because enabling it reveals saved domains to those sites. See SettingsView.
    static let loadWebsiteIcons = "loadWebsiteIcons"
    /// Whether opening the panel requires Touch ID or the device password.
    static let requireAuth = "requireAuth"
    /// How long an unlock lasts, in seconds; 0 means authenticate every time.
    static let authTimeout = "authTimeout"
    /// How results are ordered (a `SortOrder` raw value).
    static let sortOrder = "sortOrder"
    /// Opt-in: remember how often each item is used (on this Mac) and float the
    /// most-used logins to the top. Off by default, so without it the list orders
    /// purely by `sortOrder` and nothing about usage is recorded.
    static let prioritizeFrequentlyUsed = "prioritizeFrequentlyUsed"
    /// Whether a fill presses Return afterwards to submit the form. Off by
    /// default, since auto-submitting can fire before every field is in.
    static let autotypeSubmitOnFill = "autotypeSubmitOnFill"
    /// Which actions an item offers: fill, copy, or both (an `ActionMode` raw value).
    static let actionMode = "actionMode"
    /// Whether the user has dismissed the settings sponsor link, so it shows once
    /// and then stays gone.
    static let sponsorBannerDismissed = "sponsorBannerDismissed"
    /// Whether opening the panel over a browser pre-selects the item matching the
    /// active tab's URL. Reads the tab over Apple Events (Automation permission).
    static let matchActiveTab = "matchActiveTab"
    /// Whether to read Firefox's active tab too, which requires turning on
    /// Firefox's accessibility engine. Off by default and opt-in, since that has a
    /// (small, modern) cost on the browser the user may not want.
    static let firefoxAccessibility = "firefoxAccessibility"
    /// Whether to read the URL of non-browser web apps (Safari/Electron-based)
    /// from the frontmost app's web area. Opt-in: it turns on that app's
    /// accessibility, and many such apps have no matchable URL.
    static let webAppMatching = "webAppMatching"
    /// Opt-in: run the SSH agent proxy that gates key signatures behind Touch ID.
    static let sshAgentEnabled = "sshAgentEnabled"
    /// Optional vault name the upstream agent is limited to serving keys from.
    static let sshVaultFilter = "sshVaultFilter"
    /// Advanced override for the upstream `pass-cli` agent socket path; empty uses
    /// the default `~/.ssh/proton-pass-agent.sock`.
    static let sshUpstreamSocketPath = "sshUpstreamSocketPath"
    /// Whether to publish `SSH_AUTH_SOCK` to the login session (via `launchctl`)
    /// so tools that read the variable, not `~/.ssh/config`, use the proxy too.
    static let sshSetEnvVar = "sshSetEnvVar"
    /// Whether approving an app once stops it prompting again (adds it to the
    /// trusted-apps list); off means every signature asks.
    static let sshRememberApprovedApps = "sshRememberApprovedApps"
    /// How long one approval covers further signatures from the same program and
    /// key, in seconds (an `SSHApprovalWindow` raw value).
    static let sshApprovalWindow = "sshApprovalWindow"
}

/// What actions an item offers, and so what picking a field does. The detail
/// rows and the keyboard shortcuts both follow it.
enum ActionMode: String, CaseIterable, Identifiable {
    /// Fill is the primary on each field, with copy as a secondary (⌘↩ or icon).
    case fillAndCopy
    /// Only fill actions, for someone who never wants the clipboard.
    case fillOnly
    /// Only copy actions, the classic clipboard-first behaviour.
    case copyOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fillAndCopy: return "Fill and copy"
        case .fillOnly: return "Fill only"
        case .copyOnly: return "Copy only"
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> ActionMode {
        defaults.string(forKey: SettingKey.actionMode).flatMap(ActionMode.init) ?? .fillAndCopy
    }
}

/// How search results are ordered.
enum SortOrder: String, CaseIterable, Identifiable {
    case lastModified
    case alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastModified: return "Recently modified"
        case .alphabetical: return "Alphabetical"
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> SortOrder {
        defaults.string(forKey: SettingKey.sortOrder).flatMap(SortOrder.init) ?? .lastModified
    }
}

/// How long one SSH approval covers further signatures from the same program on
/// the same key.
enum SSHApprovalWindow: Int, CaseIterable, Identifiable {
    case everySignature = 0
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600
    case eightHours = 28800

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .everySignature: return "Every signature"
        case .fiveMinutes: return "After 5 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        case .oneHour: return "After 1 hour"
        case .eightHours: return "After 8 hours"
        }
    }

    /// "Every signature" still keeps a few seconds of grace, or one `git push`
    /// that signs twice would ask twice.
    var duration: TimeInterval {
        self == .everySignature ? 15 : TimeInterval(rawValue)
    }

    static func current(_ defaults: UserDefaults = .standard) -> SSHApprovalWindow {
        guard defaults.object(forKey: SettingKey.sshApprovalWindow) != nil else { return .fiveMinutes }
        return SSHApprovalWindow(rawValue: defaults.integer(forKey: SettingKey.sshApprovalWindow)) ?? .fiveMinutes
    }
}

/// How long an unlock stays valid before the panel asks again.
enum AuthTimeout: Int, CaseIterable, Identifiable {
    case everyTime = 0
    case fiveMinutes = 300
    case thirtyMinutes = 1800
    case oneHour = 3600
    case threeHours = 10800
    case sixHours = 21600
    case nineHours = 32400

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .everyTime: return "Every time"
        case .fiveMinutes: return "After 5 minutes"
        case .thirtyMinutes: return "After 30 minutes"
        case .oneHour: return "After 1 hour"
        case .threeHours: return "After 3 hours"
        case .sixHours: return "After 6 hours"
        case .nineHours: return "After 9 hours"
        }
    }
}
