// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// The update window: what version is offered, its release notes, and the choice
/// to update now or wait. The notes are shown as plain text, with no Markdown
/// engine and no third-party dependency, so the only thing rendering release
/// content is `Text`. Deliberately plain; it only appears when the user clicks a pill.
struct UpdateNotesView: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                Text(controller.available?.releaseNotes ?? "")
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("A new version is available")
                    .font(.system(size: 15, weight: .semibold))
                Text(versionLine)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Later") { controller.dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Update Now") { controller.install() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var versionLine: String {
        let version = controller.available?.version ?? ""
        return version.isEmpty ? "Pass Quick Access" : "Pass Quick Access \(version)"
    }
}
