// SPDX-License-Identifier: GPL-3.0-only

import Foundation

@MainActor
final class QuickAccessViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// The actions offered for an item, in the order shown in the detail view.
    /// `openInBrowser` only appears for items that have URLs.
    enum ItemAction: Identifiable {
        case copyUsername
        case copyPassword
        case copyTOTP
        case openInBrowser

        var id: Self { self }

        var title: String {
            switch self {
            case .copyUsername: return "Copy Username"
            case .copyPassword: return "Copy Password"
            case .copyTOTP: return "Copy One-Time Code"
            case .openInBrowser: return "Open in Browser"
            }
        }

        var shortcut: String {
            switch self {
            case .copyUsername: return "⌘C"
            case .copyPassword: return "⌘⇧C"
            case .copyTOTP: return "⌘⌥C"
            case .openInBrowser: return "⌥↩"
            }
        }
    }

    static let signedOutMessage = "Signed out of Proton Pass. Run `pass-cli login` in Terminal, then reopen."

    @Published var query = "" {
        // Only refilter on a real change: a no-op rewrite (e.g. the text field
        // rebinding when the panel reopens) must not reset a resumed detail view.
        didSet { if query != oldValue { refilter() } }
    }
    @Published private(set) var results: [ItemSummary] = []
    @Published var selection: ItemSummary.ID? {
        didSet { if selection != oldValue { schedulePasswordPrefetch() } }
    }
    @Published private(set) var loadState: LoadState = .idle
    @Published var toast: String?
    /// Bumped on each copy so the view can flash the selection.
    @Published private(set) var copyFlashes = 0
    /// Non-nil while the detail view is open for an item.
    @Published private(set) var detailItem: ItemSummary?
    @Published var actionSelection: ItemAction = .copyUsername
    /// Non-nil while choosing which of several URLs to open.
    @Published private(set) var urlChoices: [String]?
    @Published var urlSelection = 0

    /// Invoked when an action should dismiss the panel.
    var onDismiss: (() -> Void)?

    private let client: PassCLIClient
    private var index = SearchIndex(items: [])
    /// The password for the selected item, fetched ahead of a copy so the copy
    /// is instant. Holds at most one secret, cleared when the panel hides.
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedPassword: (reference: ItemReference, value: SensitiveString)?
    /// When the user last completed an action, and on which item, used to resume
    /// into that item's detail view if the panel is reopened shortly after.
    private var lastActionAt: Date?
    private var resumeItem: ItemSummary?
    private let resumeWindow: TimeInterval = 30

    init(client: PassCLIClient) {
        self.client = client
    }

    var spansMultipleVaults: Bool { index.spansMultipleVaults }
    var isShowingDetail: Bool { detailItem != nil }
    var isChoosingURL: Bool { urlChoices != nil }

    /// The actions available for the current item: a copy action only when the
    /// item actually has that field, and Open in Browser only when it has a URL.
    var availableActions: [ItemAction] {
        guard let item = actionTarget else { return [] }
        var actions: [ItemAction] = []
        if item.account != nil { actions.append(.copyUsername) }
        if item.hasPassword { actions.append(.copyPassword) }
        if item.hasTOTP { actions.append(.copyTOTP) }
        if !item.urls.isEmpty { actions.append(.openInBrowser) }
        return actions
    }

    var hasContent: Bool {
        if case .failed = loadState { return true }
        return !query.isEmpty
    }

    var selectedItem: ItemSummary? {
        results.first { $0.id == selection }
    }

    /// The item an action applies to: the one in detail, or the selected row.
    private var actionTarget: ItemSummary? { detailItem ?? selectedItem }

    func loadIfNeeded() async {
        guard loadState != .ready, loadState != .loading else { return }
        await reload()
    }

    func reload() async {
        loadState = .loading
        do {
            index = SearchIndex(items: try await client.indexLoginItems())
            loadState = .ready
            refilter()
        } catch let error as PassCLIError where error.isAuthenticationFailure {
            loadState = .failed(Self.signedOutMessage)
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    // MARK: - Navigation

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let ids = results.map(\.id)
        let current = selection.flatMap(ids.firstIndex(of:)) ?? 0
        let next = min(max(current + offset, 0), ids.count - 1)
        selection = ids[next]
    }

    func jumpToStart() {
        if isChoosingURL {
            urlSelection = 0
        } else if isShowingDetail {
            actionSelection = availableActions.first ?? actionSelection
        } else {
            selection = results.first?.id
        }
    }

    func jumpToEnd() {
        if let urlChoices, isChoosingURL {
            urlSelection = max(urlChoices.count - 1, 0)
        } else if isShowingDetail {
            actionSelection = availableActions.last ?? actionSelection
        } else {
            selection = results.last?.id
        }
    }

    func openDetail() {
        guard selectedItem != nil else { return }
        detailItem = selectedItem
        urlChoices = nil
        actionSelection = availableActions.first ?? .copyPassword
    }

    func closeDetail() {
        detailItem = nil
        urlChoices = nil
    }

    func moveAction(by offset: Int) {
        let actions = availableActions
        let current = actions.firstIndex(of: actionSelection) ?? 0
        let next = min(max(current + offset, 0), actions.count - 1)
        actionSelection = actions[next]
    }

    // MARK: - URL chooser

    func moveURL(by offset: Int) {
        guard let urlChoices else { return }
        urlSelection = min(max(urlSelection + offset, 0), urlChoices.count - 1)
    }

    func openSelectedURL() {
        guard let urlChoices, urlChoices.indices.contains(urlSelection) else { return }
        WebLink.open(urlChoices[urlSelection])
        finish(with: "Opening in browser")
    }

    func closeURLChooser() {
        urlChoices = nil
    }

    // MARK: - Actions

    func runSelectedAction() async {
        await perform(actionSelection)
    }

    func perform(_ action: ItemAction) async {
        guard let item = actionTarget, availableActions.contains(action) else { return }
        switch action {
        case .copyUsername:
            guard let account = item.account else { toast = "No username for this item"; return }
            Clipboard.copy(account)
            registerCopy(.copyUsername)
            finish(with: "Username copied")
        case .copyPassword:
            do {
                Clipboard.copy(secret: try await password(for: item.reference))
                registerCopy(.copyPassword)
                finish(with: "Password copied")
            } catch {
                report(error, fallback: "Couldn't read the password")
            }
        case .copyTOTP:
            do {
                Clipboard.copy(secret: try await client.totp(for: item.reference))
                registerCopy(.copyTOTP)
                finish(with: "One-time code copied")
            } catch {
                report(error, fallback: "No one-time code for this item")
            }
        case .openInBrowser:
            guard !item.urls.isEmpty else { return }
            if item.urls.count == 1 {
                WebLink.open(item.urls[0])
                finish(with: "Opening in browser")
            } else {
                urlChoices = item.urls
                urlSelection = 0
            }
        }
    }

    func dismiss() {
        onDismiss?()
    }

    // MARK: - Password prefetch

    /// Returns the prefetched password when it matches, otherwise waits for an
    /// in-flight prefetch, and only then fetches fresh.
    private func password(for reference: ItemReference) async throws -> SensitiveString {
        if let prefetched = prefetchedPassword, prefetched.reference == reference {
            return prefetched.value
        }
        await prefetchTask?.value
        if let prefetched = prefetchedPassword, prefetched.reference == reference {
            return prefetched.value
        }
        return try await client.password(for: reference)
    }

    /// Warms the selected item's password after a short pause, so quick scrolling
    /// doesn't spawn a request per row. Only one secret is held at a time.
    private func schedulePasswordPrefetch() {
        prefetchTask?.cancel()
        prefetchedPassword = nil
        guard let item = selectedItem else { return }
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            guard let value = try? await self.client.password(for: item.reference) else { return }
            guard !Task.isCancelled, self.selection == item.id else { return }
            self.prefetchedPassword = (item.reference, value)
        }
    }

    /// Drops any prefetched secret. Called when the panel hides.
    func clearTransientSecrets() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedPassword = nil
    }

    /// Highlights the copied field and triggers a flash on the selection.
    private func registerCopy(_ action: ItemAction) {
        actionSelection = action
        copyFlashes += 1
    }

    private func finish(with message: String) {
        toast = message
        lastActionAt = Date()
        resumeItem = actionTarget
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            onDismiss?()
        }
    }

    /// Prepares the view model for a fresh open, or keeps the previous session
    /// when the panel is reopened within the resume window so the user can grab
    /// another field from the same item.
    func prepareForShow() {
        toast = nil
        let shouldResume = lastActionAt.map { Date().timeIntervalSince($0) < resumeWindow } ?? false
        if shouldResume, let item = resumeItem {
            // Reopen directly in the item's detail view.
            urlChoices = nil
            selection = item.id
            detailItem = item
            schedulePasswordPrefetch()
            return
        }
        lastActionAt = nil
        resumeItem = nil
        detailItem = nil
        urlChoices = nil
        query = ""
        selection = results.first?.id
    }

    /// A lost session can surface on any command, so surface it the same way
    /// wherever it happens.
    private func report(_ error: Error, fallback: String) {
        if let cliError = error as? PassCLIError, cliError.isAuthenticationFailure {
            loadState = .failed(Self.signedOutMessage)
        } else {
            toast = fallback
        }
    }

    private func refilter() {
        // Editing the query returns to the list from a detail view.
        detailItem = nil
        urlChoices = nil
        results = index.search(query, sortOrder: SortOrder.current())
        // Always select the top match: keeping a prior selection would leave the
        // highlight on an item that the new ranking pushed down the list.
        selection = results.first?.id
    }
}
