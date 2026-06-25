// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices

/// Reads the URL of the active tab (or web app) from the frontmost app, so the
/// panel can pre-select the matching item. Safari and Chromium browsers answer
/// over Apple Events (the one-time Automation permission). Gecko browsers
/// (Firefox, Zen and their kin) and other web apps (Safari/Electron web apps)
/// don't script a URL, so they're read through Accessibility, which needs their
/// accessibility engine turned on; both are behind opt-ins since that has a
/// (small, modern) cost. A plain app, a missing window, or a withheld permission
/// yields nil and the panel opens as usual.
enum BrowserContext {
    /// Browsers that expose the front window's `active tab` (Chromium family).
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "company.thebrowser.Browser",
    ]
    /// Browsers that expose the front window's `current tab` (Safari family).
    private static let safari: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]
    /// Gecko browsers, read through Accessibility since they aren't scriptable.
    private static let gecko: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "app.zen-browser.zen",
        "org.mozilla.librewolf", "net.waterfox.waterfox", "net.mullvad.mullvadbrowser",
    ]

    /// The active tab's URL for a frontmost browser, or nil for a non-browser, a
    /// browser with no window, or when the needed permission isn't granted.
    static func activeTabURL(of app: NSRunningApplication) -> String? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        if safari.contains(bundleID) { return scriptedURL(bundleID: bundleID, tab: "current tab") }
        if chromium.contains(bundleID) { return scriptedURL(bundleID: bundleID, tab: "active tab") }
        if gecko.contains(bundleID) { return geckoURL(pid: app.processIdentifier) }
        // A non-browser web app (a Safari/Chromium web app, an Electron app):
        // read its web area's URL if that opt-in is on. Returns nil when off.
        return webAppURL(pid: app.processIdentifier)
    }

    /// Whether the bundle id is a Gecko browser (read through Accessibility).
    static func isGecko(_ bundleID: String?) -> Bool {
        bundleID.map(gecko.contains) ?? false
    }

    /// Turns on a Gecko browser's accessibility tree ahead of time, so the URL is
    /// readable the moment the panel opens. Activation is asynchronous on the
    /// browser's side, so this is done when the browser comes to the front rather
    /// than waiting until the read. No-op unless the feature is opted into.
    static func activateAccessibility(of app: NSRunningApplication) {
        guard UserDefaults.standard.bool(forKey: SettingKey.firefoxAccessibility), AXIsProcessTrusted() else { return }
        enableAccessibility(AXUIElementCreateApplication(app.processIdentifier))
    }

    /// Turns on a Gecko or Chromium app's accessibility tree. Both attributes are
    /// set on purpose: Zen comes up with AXManualAccessibility alone, but Firefox
    /// only exposes its tree once AXEnhancedUserInterface is set too.
    private static func enableAccessibility(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Asks a scriptable browser for its front window's tab URL over Apple Events.
    private static func scriptedURL(bundleID: String, tab: String) -> String? {
        let source = "tell application id \"\(bundleID)\" to get URL of \(tab) of front window"
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }

    /// Reads a Gecko browser's active tab through Accessibility. Turns on the
    /// browser's accessibility tree so its web area is exposed, then reads that
    /// area's URL, falling back to the address bar. Opt-in and gated on the
    /// Accessibility permission; any miss returns nil.
    private static func geckoURL(pid: pid_t) -> String? {
        guard UserDefaults.standard.bool(forKey: SettingKey.firefoxAccessibility), AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // Ensure the tree is on, in case the front-app pre-warm hasn't run.
        enableAccessibility(app)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        return webAreaURL(in: window) ?? addressBarValue(in: window)
    }

    /// Reads a non-browser web app's URL from its web area. Used for Safari and
    /// Electron web apps, which have no scripting and no address bar. Opt-in and
    /// gated on the Accessibility permission.
    private static func webAppURL(pid: pid_t) -> String? {
        guard UserDefaults.standard.bool(forKey: SettingKey.webAppMatching), AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        enableAccessibility(app)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { return nil }
        return webAreaURL(in: window)
    }

    /// The first web area's real URL within a window. Never descends into the web
    /// area, so the scan stays within the chrome and doesn't walk the whole page.
    private static func webAreaURL(in window: AXUIElement) -> String? {
        var queue = [window]
        var scanned = 0
        while !queue.isEmpty, scanned < 1500 {
            let node = queue.removeFirst()
            scanned += 1
            if string(node, kAXRoleAttribute) == "AXWebArea" {
                if let webURL = url(node, "AXURL") { return webURL }
                continue
            }
            queue.append(contentsOf: children(node))
        }
        return nil
    }

    /// The value of the address bar text field, for a Gecko browser whose current
    /// page exposes no web area URL (e.g. an internal page).
    private static func addressBarValue(in window: AXUIElement) -> String? {
        var queue = [window]
        var scanned = 0
        while !queue.isEmpty, scanned < 1500 {
            let node = queue.removeFirst()
            scanned += 1
            let role = string(node, kAXRoleAttribute)
            if role == "AXWebArea" { continue }
            if role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String),
               let value = string(node, kAXValueAttribute),
               let host = WebHost.from(value), host.contains(".") {
                return value
            }
            queue.append(contentsOf: children(node))
        }
        return nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func url(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }
}

/// Host comparison for matching a browser tab to a saved item's URLs.
enum WebHost {
    /// The bare host of a URL string, tolerant of a missing scheme and dropping a
    /// leading `www.`, so "https://www.Example.com/login" and "example.com" both
    /// reduce to "example.com".
    static func from(_ urlString: String) -> String? {
        var string = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !string.isEmpty else { return nil }
        if !string.contains("://") { string = "https://" + string }
        guard let host = URLComponents(string: string)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Whether two hosts refer to the same site: equal, or one a subdomain of the
    /// other (so `login.example.com` matches a saved `example.com`).
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasSuffix("." + rhs) || rhs.hasSuffix("." + lhs)
    }
}
