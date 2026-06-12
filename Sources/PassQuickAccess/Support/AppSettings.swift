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

/// How long an unlock stays valid before the panel asks again.
enum AuthTimeout: Int, CaseIterable, Identifiable {
    case everyTime = 0
    case fiveMinutes = 300
    case thirtyMinutes = 1800
    case oneHour = 3600
    case threeHours = 10800
    case sixHours = 21600

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .everyTime: return "Every time"
        case .fiveMinutes: return "After 5 minutes"
        case .thirtyMinutes: return "After 30 minutes"
        case .oneHour: return "After 1 hour"
        case .threeHours: return "After 3 hours"
        case .sixHours: return "After 6 hours"
        }
    }
}
