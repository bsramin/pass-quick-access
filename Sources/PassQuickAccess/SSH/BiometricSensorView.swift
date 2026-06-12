// SPDX-License-Identifier: GPL-3.0-only

import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// The Touch ID sensor, embedded in our own window via `LAAuthenticationView` so
/// the prompt lives in the approval card. It's bound to the `LAContext` the
/// coordinator evaluates, so touching the sensor drives it.
struct BiometricSensorView: NSViewRepresentable {
    let context: LAContext

    func makeNSView(context: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: self.context, controlSize: .large)
    }

    func updateNSView(_ nsView: LAAuthenticationView, context: Context) {}
}
