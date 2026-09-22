// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// The sheet macOS shows when the user picks Pass Quick Access from the AutoFill
/// menu: the logins for this site, or the reason there aren't any.
///
/// Deliberately not a reuse of the panel's list. That one is wired to the view
/// model, the autotyper, favicons and the update pill, none of which exist here,
/// and favicons in particular would need network access in a sandboxed
/// credential provider, which is not a trade worth making for an icon.
struct AutoFillListView: View {
    @ObservedObject var model: AutoFillListModel
    let onPick: (AutoFillWire.Response.Candidate) -> Void
    let onCancel: () -> Void

    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .loading:
                centered {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        if let note = model.note {
                            Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            case .list:
                search
                Divider()
                list
            case .locked:
                centered { locked }
            case let .message(text):
                centered { message(text) }
            }
        }
        // Fills whatever the host gives it rather than insisting on a size.
        // The controller asks for one through preferredContentSize, which the
        // host may honour or ignore, and a fixed frame in here would leave a
        // margin of dead space when it ignores it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.visible, id: \.recordIdentifier) { candidate in
                    row(candidate)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(candidate) }
                }
            }
            .padding(6)
        }
    }

    private func row(_ candidate: AutoFillWire.Response.Candidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: candidate.hasOneTimeCode ? "key.horizontal" : "key")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.title).font(.system(size: 13, weight: .medium))
                if let account = candidate.account {
                    Text(account).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let vault = candidate.vaultName {
                Text(vault)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selection == candidate.recordIdentifier ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        )
        .onHover { hovering in
            selection = hovering ? candidate.recordIdentifier : nil
        }
    }

    private var locked: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("Pass Quick Access is locked").font(.system(size: 13, weight: .medium))
            Button("Unlock") { model.unlock() }
                .buttonStyle(.borderedProminent)
            Button("Cancel", action: onCancel)
                .buttonStyle(.link).font(.system(size: 11))
        }
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel", action: onCancel)
                .buttonStyle(.link).font(.system(size: 11))
        }
        .padding(.horizontal, 24)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }
}
