// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Writes values to the general pasteboard. Secrets are marked concealed and
/// transient (so well-behaved clipboard managers skip them) and are wiped after
/// a short delay, unless the user has copied something else in the meantime.
@MainActor
enum Clipboard {
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copy(secret: SensitiveString, clearingAfter delay: Duration = .seconds(30)) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(secret.reveal(), forType: .string)
        pasteboard.setString("", forType: concealedType)
        pasteboard.setString("", forType: transientType)

        let writtenChange = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount == writtenChange {
                pasteboard.clearContents()
            }
        }
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
