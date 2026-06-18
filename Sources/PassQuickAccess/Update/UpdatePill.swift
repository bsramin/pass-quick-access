// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// The small "Update" capsule shown beside the menu-bar icon and at the trailing
/// edge of the search field. Tapping it opens the notes window; it never updates
/// anything on its own. The menu-bar copy is rendered to an image, so it carries
/// its own colour rather than relying on the environment's accent.
struct UpdatePill: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.down.circle.fill")
            Text("Update")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor))
    }
}

/// The menu-bar image while an update is waiting: the key with the update pill
/// attached on its right. Rendered to an image so the pill keeps its accent; the
/// key follows the menu bar's light/dark appearance through `.primary`.
struct MenuBarIcon: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "key.fill")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            UpdatePill()
        }
        .padding(.vertical, 1)
    }
}
