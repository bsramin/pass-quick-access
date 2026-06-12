// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import LocalAuthentication
import SwiftUI

/// The SSH approval card. It carries the context (app, key, fingerprint) and the
/// Touch ID sensor itself, embedded in-window via `BiometricSensorView`, so the
/// whole prompt is one native surface instead of a card plus a system dialog.
struct SignInfoView: View {
    let appName: String
    let keyName: String
    let fingerprintShort: String
    let unverified: Bool
    let context: LAContext
    let onAppear: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 13) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 42, height: 42)

            VStack(spacing: 2) {
                Text("SSH key request")
                    .font(.headline)
                Text("Authorize the signature with Touch ID")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            keyEntry

            HStack(spacing: 5) {
                Image(systemName: "terminal")
                Text("Requested by ") + Text(appName).fontWeight(.medium).foregroundColor(.primary)
                if unverified {
                    Text("(unverified)").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Divider()

            HStack(spacing: 12) {
                Button("Deny", role: .cancel, action: onDeny)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Text("Touch ID to approve")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                BiometricSensorView(context: context)
                    .frame(width: 40, height: 40)
            }
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(width: 380)
        .background(VisualEffectView())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear(perform: onAppear)
    }

    /// The key being used, styled like the Pass entry it comes from.
    private var keyEntry: some View {
        HStack(spacing: 11) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    LinearGradient(colors: [Color(red: 0.55, green: 0.42, blue: 1), Color(red: 0.25, green: 0.5, blue: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(keyName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(fingerprintShort)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}
