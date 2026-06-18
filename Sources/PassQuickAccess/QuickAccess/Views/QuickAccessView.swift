// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct QuickAccessView: View {
    @ObservedObject var viewModel: QuickAccessViewModel
    @ObservedObject var updateController: UpdateController
    @FocusState private var searchFocused: Bool
    @State private var flashing = false

    /// Rows moved per Page Up/Down, matching the visible window height.
    private let pageStep = 8

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if viewModel.hasContent {
                Divider()
                if viewModel.isShowingDetail, let item = viewModel.detailItem {
                    detail(for: item)
                } else {
                    content
                    // The shortcut footer only makes sense when there are results to
                    // act on, not in the signed-out, loading or empty states.
                    if !viewModel.results.isEmpty { listFooter }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VisualEffectView())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .overlay(alignment: .bottom) { toast }
        .onAppear { searchFocused = true }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.pageUp) { if !viewModel.isShowingDetail { viewModel.moveSelection(by: -pageStep) }; return .handled }
        .onKeyPress(.pageDown) { if !viewModel.isShowingDetail { viewModel.moveSelection(by: pageStep) }; return .handled }
        .onKeyPress(.home) { viewModel.jumpToStart(); return .handled }
        .onKeyPress(.end) { viewModel.jumpToEnd(); return .handled }
        .onKeyPress(.rightArrow) {
            guard !viewModel.isShowingDetail else { return .ignored }
            viewModel.openDetail()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if viewModel.isChoosingURL { viewModel.closeURLChooser(); return .handled }
            if viewModel.isShowingDetail { viewModel.closeDetail(); return .handled }
            return .ignored
        }
        .onKeyPress(keys: [.return]) { press in
            if viewModel.isSignedOut {
                if !viewModel.isRecovering {
                    if viewModel.canReconnect { viewModel.requestReconnect() } else { viewModel.requestSignIn() }
                }
                return .handled
            }
            if press.modifiers.contains(.option) {
                Task { await viewModel.perform(.openInBrowser) }
            } else if viewModel.isChoosingURL {
                viewModel.openSelectedURL()
            } else if viewModel.isShowingDetail {
                Task { await viewModel.runSelectedAction() }
            } else {
                viewModel.openDetail()
            }
            return .handled
        }
        .onKeyPress(keys: ["c", "C"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            let action: QuickAccessViewModel.ItemAction = press.modifiers.contains(.shift) ? .copyPassword
                : press.modifiers.contains(.option) ? .copyTOTP
                : .copyUsername
            Task { await viewModel.perform(action) }
            return .handled
        }
        .onKeyPress(keys: ["l", "L"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            // Reveals the highlighted field in detail, or the password (else the
            // username) of the selected row from the list.
            let action: QuickAccessViewModel.ItemAction = viewModel.isShowingDetail
                ? viewModel.actionSelection
                : viewModel.availableActions.contains(.copyPassword) ? .copyPassword : .copyUsername
            Task { await viewModel.reveal(action) }
            return .handled
        }
        .onExitCommand {
            if viewModel.isRecovering { viewModel.cancelRecovery() }
            else if viewModel.isChoosingURL { viewModel.closeURLChooser() }
            else if viewModel.isShowingDetail { viewModel.closeDetail() }
            else { viewModel.dismiss() }
        }
        .onChange(of: viewModel.copyFlashes) { _, _ in
            flashing = true
            withAnimation(.easeOut(duration: 0.35)) { flashing = false }
        }
    }

    private func move(_ offset: Int) {
        if viewModel.isChoosingURL {
            viewModel.moveURL(by: offset)
        } else if viewModel.isShowingDetail {
            viewModel.moveAction(by: offset)
        } else {
            viewModel.moveSelection(by: offset)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            TextField("Search in Proton Pass", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .focused($searchFocused)
            if updateController.available != nil {
                UpdatePill()
                    .onTapGesture { updateController.showReleaseNotes() }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if viewModel.isSignedOut {
            centered { signedOut }
        } else if case .failed(let message) = viewModel.loadState {
            centered { statusText(message, systemImage: "exclamationmark.triangle") }
        } else if !viewModel.results.isEmpty {
            resultsList
        } else if viewModel.isIndexing {
            // Still streaming vaults in: a query with no match yet might just be in
            // a vault that hasn't arrived. Keep the loader so it doesn't read as
            // "not found" before the index is complete.
            centered { loading }
        } else if viewModel.loadState == .ready {
            centered { statusText("No matches", systemImage: "magnifyingglass") }
        } else {
            centered { loading }
        }
    }

    private var loading: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(viewModel.loadingDetail ?? "Loading your items")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            if !viewModel.query.isEmpty {
                Text("Still indexing, so what you're after may not have loaded yet")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.results) { item in
                        ItemRowView(
                            item: item,
                            isSelected: item.id == viewModel.selection,
                            showsVault: viewModel.spansMultipleVaults,
                            isFlashing: item.id == viewModel.selection && flashing
                        )
                        .id(item.id)
                        .onTapGesture(count: 2) {
                            viewModel.selection = item.id
                            viewModel.openDetail()
                        }
                        .onTapGesture {
                            viewModel.selection = item.id
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: viewModel.selection) { _, selection in
                guard let selection else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selection) }
            }
        }
    }

    private var listFooter: some View {
        footerBar {
            if viewModel.isIndexing {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text(viewModel.loadingDetail ?? "Indexing…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            } else {
                hint("→", "Actions")
                hint("⌘C", "Username")
                hint("⌘⇧C", "Password")
            }
            Spacer()
            hint("esc", "Close")
        }
    }

    // MARK: - Detail

    private func detail(for item: ItemSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ItemIcon(item: item)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let subtitle = detailSubtitle(item) {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    viewModel.closeDetail()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let urls = viewModel.urlChoices {
                VStack(spacing: 2) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        urlRow(url, isSelected: index == viewModel.urlSelection, index: index)
                    }
                }
                .padding(8)
            } else {
                VStack(spacing: 2) {
                    ForEach(viewModel.availableActions) { action in
                        actionRow(action)
                    }
                }
                .padding(8)
            }

            detailFooter(item)
        }
    }

    private func urlRow(_ url: String, isSelected: Bool, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
            Text(url).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
        )
        .foregroundStyle(isSelected ? .white : .primary)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.urlSelection = index
            viewModel.openSelectedURL()
        }
    }

    private func actionRow(_ action: QuickAccessViewModel.ItemAction) -> some View {
        let isSelected = action == viewModel.actionSelection
        return HStack {
            Text(action.title)
            Spacer()
            Text(action.shortcut)
                .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
        )
        .foregroundStyle(isSelected ? .white : .primary)
        .brightness(isSelected && flashing ? 0.35 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.actionSelection = action
            Task { await viewModel.runSelectedAction() }
        }
    }

    private func detailFooter(_ item: ItemSummary) -> some View {
        footerBar {
            Image(systemName: "folder")
            Text("Located in \(item.vaultName)").lineLimit(1)
            Spacer()
            hint("⌘L", "Large type")
            hint("←", "Back")
        }
    }

    private func detailSubtitle(_ item: ItemSummary) -> String? {
        [item.account, item.urls.first].compactMap { $0 }.joined(separator: "  ·  ").nilIfEmpty
    }

    // MARK: - Shared chrome

    private func footerBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(.quaternary.opacity(0.4))
            .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = viewModel.toast {
            Text(toast)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .padding(.bottom, 42)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }

    /// A fixed-height centered area for the empty, loading and error states. Its
    /// height matches what the controller reserves, so the content never
    /// overflows the window and clips the panel's rounded corners.
    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: Self.statusAreaHeight)
    }

    static let statusAreaHeight: CGFloat = 140

    private func statusText(_ message: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    @ViewBuilder
    private var signedOut: some View {
        VStack(spacing: 10) {
            if viewModel.isRecovering {
                ProgressView().controlSize(.small)
                Text(viewModel.canReconnect ? "Reconnecting…" : "Waiting for sign in…")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if !viewModel.canReconnect {
                    Text("Finish signing in in your browser").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Button("Cancel") { viewModel.cancelRecovery() }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            } else {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 22)).foregroundStyle(.secondary)
                Text(QuickAccessViewModel.signedOutMessage)
                    .font(.system(size: 13, weight: .medium))
                if viewModel.canReconnect {
                    Button("Reconnect") { viewModel.requestReconnect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    Button("Sign in with browser") { viewModel.requestSignIn() }
                        .buttonStyle(.link).font(.system(size: 11))
                } else {
                    Button("Sign in to Proton Pass") { viewModel.requestSignIn() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    Text("Opens Proton's login in your browser").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
