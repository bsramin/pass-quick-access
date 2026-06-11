// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Bridges `NSVisualEffectView` so the panel can sit on the system's vibrant
/// material rather than a flat fill.
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
