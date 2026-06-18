// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A newer release the user can move to, surfaced by the menu-bar and search-bar
/// pills and shown in the update window. The release notes are kept as raw
/// Markdown so the window can render them; nothing here triggers an install on
/// its own.
struct AvailableUpdate: Equatable {
    let version: String
    let releaseNotes: String
}
