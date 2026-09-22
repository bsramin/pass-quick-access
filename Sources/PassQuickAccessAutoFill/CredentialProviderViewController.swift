// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import AuthenticationServices
import SwiftUI

/// The credential provider macOS loads when an app or Safari asks for a
/// password or a one-time code.
///
/// It reads nothing itself. The extension is sandboxed, as the system requires
/// of a credential provider, so it cannot run `pass-cli`; it asks the app over
/// the shared container and the app answers. That is not only a sandbox
/// workaround: `pass-cli` keeps one session on disk and rotates its refresh
/// token on use, so a second process reading vaults would sign the user out.
///
/// Passkeys are not offered, here or in the Info.plist. Providing one means
/// signing the WebAuthn challenge with the credential's private key, and
/// `pass-cli` exposes neither the key nor any signing operation.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private var hosted: NSView?

    /// The size the sheet asks the host for. The host is free to ignore it, but
    /// without it the view starts at zero and the list has nowhere to draw.
    private static let contentSize = NSSize(width: 380, height: 300)

    /// Required, and easy to leave out. AppKit's NSViewController does not
    /// invent an empty view the way UIKit does: with no nib and no override it
    /// raises when anything first touches `view`, which for an app extension
    /// means the sheet vanishes the moment it is asked to appear, with no crash
    /// report to explain it.
    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        preferredContentSize = Self.contentSize
    }

    /// Last line of defence. If the host put the sheet on screen without
    /// calling any of the prepare methods, something is still better than a
    /// blank rectangle: show everything and let the user search.
    override func viewWillAppear() {
        super.viewWillAppear()
        guard hosted == nil else { return }
        present([], kind: .password)
    }

    // MARK: - Choosing from a list

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        present(serviceIdentifiers, kind: .password)
    }

    /// The variant the system prefers when a request could involve passkeys.
    /// Overridden even though this provider offers none: if only the older one
    /// exists, the system calls neither and the sheet comes up empty.
    @available(macOS 14.0, *)
    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        requestParameters: ASPasskeyCredentialRequestParameters
    ) {
        present(serviceIdentifiers, kind: .password)
    }

    @available(macOS 15.0, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        present(serviceIdentifiers, kind: .oneTimeCode)
    }

    override func prepareInterfaceForExtensionConfiguration() {
        // Nothing to configure here: what AutoFill may do is decided in the
        // app's own settings, where the rest of its switches already live.
        present(configurationNotice: "AutoFill is set up in Pass Quick Access, under Settings.")
    }

    private func present(_ services: [ASCredentialServiceIdentifier], kind: AutoFillWire.Request.Kind) {
        let model = AutoFillListModel(services: services.map(\.identifier), kind: kind)
        install(NSHostingView(rootView: AutoFillListView(
            model: model,
            onPick: { [weak self] candidate in self?.complete(with: candidate, from: model, kind: kind) },
            onCancel: { [weak self] in self?.cancel(.userCanceled) }
        )))
        model.load()
    }

    private func complete(
        with candidate: AutoFillWire.Response.Candidate,
        from model: AutoFillListModel,
        kind: AutoFillWire.Request.Kind
    ) {
        Task { @MainActor in
            // A nil means the model has already put the reason on screen.
            guard let secret = await model.secret(for: candidate) else { return }
            deliver(secret, account: candidate.account ?? "", kind: kind)
        }
    }

    // MARK: - Filling a credential the system already knows about

    /// The silent path, taken when the user picks a named suggestion straight
    /// from the AutoFill menu. Nothing may be shown here, so anything short of
    /// an immediate answer has to become `userInteractionRequired` and let the
    /// system come back through the interface path below.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        guard let identifier = credentialRequest.credentialIdentity.recordIdentifier else {
            cancel(.credentialIdentityNotFound)
            return
        }
        let kind = Self.kind(of: credentialRequest)
        let account = credentialRequest.credentialIdentity.user
        Task { @MainActor in
            // One attempt, no retry: someone waiting on a menu is better served
            // by our own sheet appearing than by a pause they cannot read.
            guard let secret = await Self.read(identifier, kind: kind, authenticated: false) else {
                self.cancel(.userInteractionRequired)
                return
            }
            self.deliver(secret, account: account, kind: kind)
        }
    }

    /// The follow-up, once the system has decided the user must be involved.
    /// Here the lock can be answered and a failure can be explained.
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        guard let identifier = credentialRequest.credentialIdentity.recordIdentifier else {
            cancel(.credentialIdentityNotFound)
            return
        }
        let identity = credentialRequest.credentialIdentity
        let kind = Self.kind(of: credentialRequest)
        let model = AutoFillListModel(services: [identity.serviceIdentifier.identifier], kind: kind)
        install(NSHostingView(rootView: AutoFillListView(
            model: model,
            onPick: { [weak self] candidate in self?.complete(with: candidate, from: model, kind: kind) },
            onCancel: { [weak self] in self?.cancel(.userCanceled) }
        )))

        // The system already knows which item this is, so go straight for it.
        // Anything in the way (the lock, a slow read, a vanished item) surfaces
        // in the same view, which is why it is installed first.
        complete(
            with: AutoFillWire.Response.Candidate(
                recordIdentifier: identifier,
                title: identity.serviceIdentifier.identifier,
                account: identity.user,
                vaultName: nil,
                hasOneTimeCode: kind == .oneTimeCode,
                matchesSite: true
            ),
            from: model,
            kind: kind
        )
    }

    // MARK: - Plumbing

    private static func kind(of request: any ASCredentialRequest) -> AutoFillWire.Request.Kind {
        if #available(macOS 15.0, *), request.type == .oneTimeCode { return .oneTimeCode }
        return .password
    }

    private static func read(
        _ recordIdentifier: String,
        kind: AutoFillWire.Request.Kind,
        authenticated: Bool
    ) async -> String? {
        let body: AutoFillWire.Request.Body = kind == .oneTimeCode
            ? .oneTimeCode(recordIdentifier: recordIdentifier)
            : .password(recordIdentifier: recordIdentifier)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let response = try? AutoFillClient.send(.init(body, authenticated: authenticated))
                guard case let .secret(value) = response?.body else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: value)
            }
        }
    }

    /// Hands the value to whoever asked. The plaintext lives for exactly as long
    /// as this call and is never written down by the extension.
    private func deliver(_ secret: String, account: String, kind: AutoFillWire.Request.Kind) {
        if kind == .oneTimeCode, #available(macOS 15.0, *) {
            extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: secret))
            return
        }
        // Belt as well as braces: the app already leaves out logins with no
        // username, because Safari turns an empty user into nil and aborts
        // building the dictionary it fills from, taking the browser with it.
        // Cancelling costs this one fill; getting it wrong costs every tab.
        guard !account.isEmpty, !secret.isEmpty else {
            cancel(.credentialIdentityNotFound)
            return
        }
        extensionContext.completeRequest(
            withSelectedCredential: ASPasswordCredential(user: account, password: secret)
        )
    }

    private func cancel(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: ASExtensionError(code))
    }

    private func present(configurationNotice text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(finishConfiguration))
        done.keyEquivalent = "\r"
        let stack = NSStackView(views: [label, done])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        install(stack)
    }

    @objc private func finishConfiguration() {
        extensionContext.completeExtensionConfigurationRequest()
    }

    /// Replaces whatever is on screen. The system reuses one controller across
    /// the paths above, so leaving the previous view in place would stack them.
    private func install(_ view: NSView) {
        hosted?.removeFromSuperview()
        hosted = view
        view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: self.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
    }
}
