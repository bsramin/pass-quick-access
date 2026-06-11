// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Opens a stored URL in the default browser, tolerating entries written
/// without a scheme (e.g. "example.com/login").
@MainActor
enum WebLink {
    static func open(_ string: String) {
        let normalized = string.contains("://") ? string : "https://\(string)"
        guard let url = URL(string: normalized) else { return }
        NSWorkspace.shared.open(url)
    }
}
