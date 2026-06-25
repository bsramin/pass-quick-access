// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics

/// Types a credential into the focused field of whatever app is frontmost, by
/// synthesizing real keystrokes. Unlike a browser extension it can't see fields,
/// so it types into wherever the cursor is; but because these are genuine OS key
/// events, the browser's normal input pipeline runs and framework-controlled
/// inputs (React and the like) react just as they would to a person typing.
///
/// Posting requires the Accessibility permission. The work runs on its own
/// thread, off the main actor, so the small inter-key pauses never stall the UI.
struct AutoTyper {
    /// Whether the app may post keystrokes yet. `false` until the user grants
    /// Accessibility access in System Settings.
    static var isProcessTrusted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show the one-time Accessibility prompt for this app.
    /// The option key is spelled out rather than taken from
    /// `kAXTrustedCheckOptionPrompt`, whose imported global isn't concurrency-safe.
    static func promptForAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Opens System Settings at the Accessibility pane, where the app is enabled.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Virtual key codes for the only two non-character keys we send.
    private static let tabKey: CGKeyCode = 0x30
    private static let returnKey: CGKeyCode = 0x24

    /// Posts the request's keystrokes on a background thread and returns at once.
    /// The secrets ride along in the `Sendable` request and are revealed one step
    /// at a time, so the plaintext is held no longer than the keystroke it feeds.
    func type(_ request: AutotypeRequest) {
        Thread.detachNewThread {
            // Let the target's focus settle after it became frontmost.
            Thread.sleep(forTimeInterval: 0.05)
            let source = CGEventSource(stateID: .combinedSessionState)
            for step in request.steps {
                switch step {
                case .text(let value): typeText(value, source: source)
                case .secret: request.secret.map { typeText($0.reveal(), source: source) }
                case .code: request.code.map { typeText($0.reveal(), source: source) }
                case .tab: tap(Self.tabKey, source: source)
                case .return: tap(Self.returnKey, source: source)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    /// Types arbitrary text one character at a time, carrying the Unicode through
    /// the event itself rather than mapping to key codes, so any layout and any
    /// character (accents, symbols) come out right.
    private func typeText(_ text: String, source: CGEventSource?) {
        for character in text {
            var units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.006)
        }
    }

    /// Presses and releases a single virtual key (Tab or Return).
    private func tap(_ key: CGKeyCode, source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
