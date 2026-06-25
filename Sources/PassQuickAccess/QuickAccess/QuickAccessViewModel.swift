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
    /// Each is offered only when the item has the field it needs; the fill
    /// actions type into the app that was frontmost, the copy actions go to the
    /// clipboard, and `openInBrowser` only appears for items that have URLs.
    enum ItemAction: Identifiable {
        case fillLogin
        case fillUsername
        case fillPassword
        case fillTOTP
        case copyUsername
        case copyPassword
        case copyTOTP
        case openInBrowser

        var id: Self { self }

        /// The label shown on a detail row. The field fills read as the field
        /// name, since the row fills by default and copy is a secondary on it.
        var rowLabel: String {
            switch self {
            case .fillUsername: return "Username"
            case .fillPassword: return "Password"
            case .fillTOTP: return "One-Time Code"
            default: return title
            }
        }

        /// The copy that a fill row offers as its secondary action (⌘↩ or the
        /// copy icon). Nil for rows without a single field to copy.
        var copyCounterpart: ItemAction? {
            switch self {
            case .fillUsername: return .copyUsername
            case .fillPassword: return .copyPassword
            case .fillTOTP: return .copyTOTP
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .fillLogin: return "Fill Login"
            case .fillUsername: return "Fill Username"
            case .fillPassword: return "Fill Password"
            case .fillTOTP: return "Fill One-Time Code"
            case .copyUsername: return "Copy Username"
            case .copyPassword: return "Copy Password"
            case .copyTOTP: return "Copy One-Time Code"
            case .openInBrowser: return "Open in Browser"
            }
        }

        var shortcut: String {
            switch self {
            case .fillLogin: return "⌘↩"
            case .fillUsername: return ""
            case .fillPassword: return "⌘⇧↩"
            case .fillTOTP: return "⌘⌥↩"
            case .copyUsername: return "⌘C"
            case .copyPassword: return "⌘⇧C"
            case .copyTOTP: return "⌘⌥C"
            case .openInBrowser: return "⌥↩"
            }
        }
    }

    /// Sentinel message for the signed-out state; the view renders it as a
    /// sign-in prompt rather than plain error text.
    static let signedOutMessage = "Signed out of Proton Pass"

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
    /// What the index is doing right now, shown under the loading spinner and in
    /// the list footer. Vaults are read one at a time (running `pass-cli` in
    /// parallel drops the session), so this tells the user the wait is the vaults
    /// indexing, not a hang.
    @Published private(set) var loadingDetail: String?
    /// True while vaults are still streaming in, so the footer can show progress
    /// even though usable results are already on screen.
    @Published private(set) var isIndexing = false
    /// True while waiting for a sign-in to land after the user was sent to log in.
    @Published private(set) var isRecovering = false
    /// Whether a stored access token offers a one-tap reconnect from signed-out.
    @Published var canReconnect = false
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
    /// Invoked to type a credential into the app that was frontmost. The
    /// controller hides the panel, restores that app, and posts the keystrokes.
    var onAutotype: ((AutotypeRequest) -> Void)?
    /// Invoked to show a field's value in the large-type window.
    var onReveal: ((RevealRequest) -> Void)?
    /// Invoked when the user asks to sign back in from the signed-out state.
    var onSignIn: (() -> Void)?
    /// Invoked when the user asks to reconnect using the stored access token.
    var onReconnect: (() -> Void)?
    /// Invoked when the user cancels a sign-in that's being waited on.
    var onCancelRecovery: (() -> Void)?

    /// A value to display big, with the item and field it came from.
    struct RevealRequest {
        let title: String
        let field: String
        let value: String
    }

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
    /// Captured when revealing a value, so the panel can return to the same item
    /// and field once the large-type window closes, regardless of timing.
    private var revealResume: (item: ItemSummary, inDetail: Bool, action: ItemAction)?
    /// The host of the browser tab that was open when the panel was summoned, set
    /// by the controller, used to pre-select the matching item on a fresh open.
    var contextHost: String?
    /// Set once the context host has resolved (to a detail or a list) for this
    /// open, so a later vault streaming in doesn't move things under the user.
    private var contextHonored = false
    /// True while the panel is showing the list filtered to a browser tab's domain
    /// because several items matched it. Keeps the list visible with no query.
    @Published private(set) var contextListActive = false

    init(client: PassCLIClient) {
        self.client = client
    }

    var spansMultipleVaults: Bool { index.spansMultipleVaults }
    var isShowingDetail: Bool { detailItem != nil }
    var isChoosingURL: Bool { urlChoices != nil }

    /// Whether detail rows carry a copy secondary (the copy icon and ⌘↩). Only in
    /// the combined mode; the single-purpose modes have nothing to fall back to.
    var showsRowCopy: Bool { ActionMode.current() == .fillAndCopy }
    /// Whether the current mode offers fill and copy at all, used to label the
    /// footer hints to match.
    var offersFill: Bool { ActionMode.current() != .copyOnly }
    var offersCopy: Bool { ActionMode.current() != .fillOnly }

    /// Every operation valid for the current item under the chosen mode. Used to
    /// validate a shortcut or click, so e.g. a fill shortcut does nothing in
    /// Copy-only mode.
    var availableActions: [ItemAction] {
        guard let item = actionTarget else { return [] }
        let hasUsername = item.account != nil
        let mode = ActionMode.current()
        var actions: [ItemAction] = []
        if mode != .copyOnly {
            if hasUsername && item.hasPassword { actions.append(.fillLogin) }
            if hasUsername { actions.append(.fillUsername) }
            if item.hasPassword { actions.append(.fillPassword) }
            if item.hasTOTP { actions.append(.fillTOTP) }
        }
        if mode != .fillOnly {
            if hasUsername { actions.append(.copyUsername) }
            if item.hasPassword { actions.append(.copyPassword) }
            if item.hasTOTP { actions.append(.copyTOTP) }
        }
        if !item.urls.isEmpty { actions.append(.openInBrowser) }
        return actions
    }

    /// The rows shown in the detail view. In the combined and fill modes there's
    /// one fill row per field (copy rides along as a secondary); in copy mode the
    /// rows are the copies. Open in Browser is always last when present.
    var actionRows: [ItemAction] {
        guard let item = actionTarget else { return [] }
        let hasUsername = item.account != nil
        var rows: [ItemAction] = []
        if ActionMode.current() == .copyOnly {
            if hasUsername { rows.append(.copyUsername) }
            if item.hasPassword { rows.append(.copyPassword) }
            if item.hasTOTP { rows.append(.copyTOTP) }
        } else {
            if hasUsername && item.hasPassword { rows.append(.fillLogin) }
            if hasUsername { rows.append(.fillUsername) }
            if item.hasPassword { rows.append(.fillPassword) }
            if item.hasTOTP { rows.append(.fillTOTP) }
        }
        if !item.urls.isEmpty { rows.append(.openInBrowser) }
        return rows
    }

    /// The field to reveal in large type from the list: the password if the mode
    /// exposes it, otherwise the username, in whichever variant is valid.
    var listRevealAction: ItemAction? {
        let preferred: [ItemAction] = [.fillPassword, .copyPassword, .fillUsername, .copyUsername]
        return preferred.first { availableActions.contains($0) }
    }

    var hasContent: Bool {
        if case .failed = loadState { return true }
        // A detail or a domain-filtered list can be shown with no query when the
        // browser-tab match opens directly, so the panel expands for those too.
        return !query.isEmpty || detailItem != nil || contextListActive
    }

    var isSignedOut: Bool {
        if case .failed(Self.signedOutMessage) = loadState { return true }
        return false
    }

    /// Triggered from the signed-out prompt: enters the recovering state and asks
    /// the controller to start the login flow.
    func requestSignIn() {
        guard !isRecovering else { return }
        isRecovering = true
        onSignIn?()
    }

    /// Reconnects using the stored access token instead of an interactive sign-in.
    func requestReconnect() {
        guard !isRecovering else { return }
        isRecovering = true
        onReconnect?()
    }

    /// Stops waiting on a sign-in and returns to the signed-out prompt.
    func cancelRecovery() {
        guard isRecovering else { return }
        isRecovering = false
        onCancelRecovery?()
    }

    /// Resolves a recovery attempt. On success the index is reloaded so the panel
    /// is usable again without reopening.
    func finishRecovery(succeeded: Bool) async {
        isRecovering = false
        if succeeded { await reload() }
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
        loadingDetail = nil
        isIndexing = true
        defer { isIndexing = false }

        var accumulated: [ItemSummary] = []
        do {
            for try await vault in client.indexLoginItems() {
                accumulated.append(contentsOf: vault.items)
                index = SearchIndex(items: accumulated)
                // Show the first vault's items right away; keep the spinner only
                // while nothing has come back yet.
                if !accumulated.isEmpty { loadState = .ready }
                loadingDetail = vault.position < vault.total
                    ? "Indexing \(vault.position) of \(vault.total) vaults"
                    : nil
                refilterPreservingSelection()
                applyContextSelection()
            }
            loadState = .ready
            loadingDetail = nil
            refilterPreservingSelection()
            applyContextSelection()
        } catch let error as PassCLIError where error.isAuthenticationFailure {
            // A vault that's already on screen is more useful than a blank prompt;
            // only fall back to the signed-out state when nothing was read.
            if accumulated.isEmpty { enterFailure(Self.signedOutMessage) } else { loadState = .ready }
        } catch {
            if accumulated.isEmpty { enterFailure(String(describing: error)) } else { loadState = .ready }
        }
    }

    /// Switches to a full-window status state, clearing any list or detail left
    /// over from before the failure so the panel resizes and drops the footer.
    private func enterFailure(_ message: String) {
        loadState = .failed(message)
        loadingDetail = nil
        index = SearchIndex(items: [])
        results = []
        detailItem = nil
        urlChoices = nil
        selection = nil
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
            actionSelection = actionRows.first ?? actionSelection
        } else {
            selection = results.first?.id
        }
    }

    func jumpToEnd() {
        if let urlChoices, isChoosingURL {
            urlSelection = max(urlChoices.count - 1, 0)
        } else if isShowingDetail {
            actionSelection = actionRows.last ?? actionSelection
        } else {
            selection = results.last?.id
        }
    }

    func openDetail() {
        guard selectedItem != nil else { return }
        detailItem = selectedItem
        urlChoices = nil
        contextListActive = false
        actionSelection = actionRows.first ?? .copyPassword
    }

    func closeDetail() {
        detailItem = nil
        urlChoices = nil
    }

    func moveAction(by offset: Int) {
        let actions = actionRows
        guard !actions.isEmpty else { return }
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
        let submit = UserDefaults.standard.bool(forKey: SettingKey.autotypeSubmitOnFill)
        switch action {
        case .fillLogin:
            guard let account = item.account else { return }
            do {
                let secret = try await password(for: item.reference)
                requestAutotype(AutotypeRequest(steps: AutoTypePlan.login(username: account, submit: submit), secret: secret))
            } catch {
                report(error, fallback: "Couldn't read the password")
            }
        case .fillUsername:
            guard let account = item.account else { return }
            requestAutotype(AutotypeRequest(steps: AutoTypePlan.username(account)))
        case .fillPassword:
            do {
                let secret = try await password(for: item.reference)
                requestAutotype(AutotypeRequest(steps: AutoTypePlan.password(submit: submit), secret: secret))
            } catch {
                report(error, fallback: "Couldn't read the password")
            }
        case .fillTOTP:
            do {
                let code = try await client.totp(for: item.reference)
                requestAutotype(AutotypeRequest(steps: AutoTypePlan.code(submit: submit), code: code))
            } catch {
                report(error, fallback: "No one-time code for this item")
            }
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

    /// Reveals a field's value in the large-type window. Mirrors `perform`'s value
    /// fetching (passwords and codes are read fresh), but shows instead of copies
    /// and leaves the panel up; it hides on its own when the window takes focus.
    func reveal(_ action: ItemAction) async {
        guard let item = actionTarget, availableActions.contains(action) else { return }
        // Remember where we were so closing the large-type window restores it.
        revealResume = (item: item, inDetail: isShowingDetail, action: action)
        // A fill action reveals the field it would type: the login and password
        // fills show the password (the value worth reading big), the username
        // fills the username, the code fill the one-time code.
        switch action {
        case .copyUsername, .fillUsername:
            guard let account = item.account else { toast = "No username for this item"; return }
            onReveal?(RevealRequest(title: item.title, field: "Username", value: account))
        case .copyPassword, .fillLogin, .fillPassword:
            do {
                let secret = try await password(for: item.reference)
                onReveal?(RevealRequest(title: item.title, field: "Password", value: secret.reveal()))
            } catch {
                report(error, fallback: "Couldn't read the password")
            }
        case .copyTOTP, .fillTOTP:
            do {
                let code = try await client.totp(for: item.reference)
                onReveal?(RevealRequest(title: item.title, field: "One-Time Code", value: code.reveal()))
            } catch {
                report(error, fallback: "No one-time code for this item")
            }
        case .openInBrowser:
            break
        }
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

    /// Hands a resolved fill to the controller. It remembers the item so the
    /// panel can resume on it, then lets the controller hide and type; unlike a
    /// copy there's no toast, since the panel must give up focus immediately for
    /// the keystrokes to land in the target app.
    private func requestAutotype(_ request: AutotypeRequest) {
        lastActionAt = Date()
        resumeItem = actionTarget
        onAutotype?(request)
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
        contextListActive = false
        // Returning from the large-type window: restore the exact item and field.
        if let resume = revealResume {
            revealResume = nil
            urlChoices = nil
            selection = resume.item.id
            detailItem = resume.inDetail ? resume.item : nil
            if resume.inDetail {
                actionSelection = availableActions.contains(resume.action) ? resume.action : (availableActions.first ?? .copyPassword)
            }
            schedulePasswordPrefetch()
            return
        }
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
        contextHonored = false
        selection = results.first?.id
        applyContextSelection()
    }

    /// Reacts to the browser tab the panel was summoned over. A single matching
    /// item opens straight into its detail; several matches show the list filtered
    /// to that domain so the user picks. While the index is still streaming it
    /// shows the list provisionally and only commits once loaded, so a late vault
    /// doesn't flip an open detail. No-op without a context host, after the user
    /// has typed, or once a detail is open.
    private func applyContextSelection() {
        guard !contextHonored, let host = contextHost, query.isEmpty, !isShowingDetail else { return }
        let matches = index.items(matchingHost: host)
        let ready = (loadState == .ready)
        guard !matches.isEmpty else {
            if ready { contextHonored = true }
            return
        }
        if ready, matches.count == 1 {
            // Single, final match: open its detail with the actions ready.
            contextHonored = true
            contextListActive = false
            selection = matches[0].id
            detailItem = matches[0]
            actionSelection = actionRows.first ?? actionSelection
        } else {
            // Several matches (or still streaming): show the domain-filtered list.
            contextListActive = true
            results = matches
            if !matches.contains(where: { $0.id == selection }) { selection = matches.first?.id }
            if ready { contextHonored = true }
        }
    }

    /// A lost session can surface on any command, so surface it the same way
    /// wherever it happens.
    private func report(_ error: Error, fallback: String) {
        if let cliError = error as? PassCLIError, cliError.isAuthenticationFailure {
            enterFailure(Self.signedOutMessage)
        } else {
            toast = fallback
        }
    }

    private func refilter() {
        // Editing the query returns to the list from a detail view, and takes over
        // from any browser-tab suggestion.
        detailItem = nil
        urlChoices = nil
        contextListActive = false
        contextHonored = true
        results = index.search(query, sortOrder: SortOrder.current())
        // Always select the top match: keeping a prior selection would leave the
        // highlight on an item that the new ranking pushed down the list.
        selection = results.first?.id
    }

    /// Refreshes the result list against the current query as vaults stream in,
    /// without disturbing the user: it keeps the current selection if it's still
    /// present (only defaulting to the top match when it's gone) and leaves any
    /// open detail view in place.
    private func refilterPreservingSelection() {
        let previous = selection
        results = index.search(query, sortOrder: SortOrder.current())
        if let previous, results.contains(where: { $0.id == previous }) {
            selection = previous
        } else {
            selection = results.first?.id
        }
    }
}
