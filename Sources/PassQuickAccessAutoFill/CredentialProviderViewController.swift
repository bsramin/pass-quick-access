// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import AuthenticationServices

/// The credential provider macOS loads when an app or Safari asks for a
/// password.
///
/// It reads nothing itself. The extension is sandboxed, as the system requires
/// of a credential provider, so it cannot run `pass-cli`; it asks the app over
/// the shared container and the app answers. That is not only a sandbox
/// workaround: `pass-cli` keeps one session on disk and rotates its refresh
/// token on use, so a second process reading vaults would sign the user out.
///
/// Filling is not wired up yet. What works today is the channel, and this
/// reports what it finds down it.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let heading = NSTextField(labelWithString: "Pass Quick Access")
    private let detail = NSTextField(labelWithString: "Checking…")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 4

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [heading, detail, cancel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        checkChannel()
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        checkChannel()
    }

    override func prepareInterfaceForExtensionConfiguration() {
        checkChannel()
    }

    /// Asks the app how it is. Off the main thread because the client blocks:
    /// the app may be reading a vault, or not running at all, and neither is a
    /// reason to freeze the sheet the user is looking at.
    private func checkChannel() {
        detail.stringValue = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            let message = Self.describe(Result { try AutoFillClient.send(.init(.status)) })
            DispatchQueue.main.async { self.detail.stringValue = message }
        }
    }

    private static func describe(_ result: Result<AutoFillWire.Response, Error>) -> String {
        switch result {
        case let .success(response):
            guard case let .status(state) = response.body else {
                return "The app answered something unexpected."
            }
            switch state {
            case .ready: return "Connected. \(state.rawValue), filling isn't wired up yet."
            case .indexing: return "Connected, still reading your vaults."
            case .locked: return "Connected. Unlock Pass Quick Access first."
            case .signedOut: return "Connected, but signed out of Proton Pass."
            }
        case let .failure(error as AutoFillClient.Failure):
            switch error {
            case let .unavailable(reason): return "Not reachable: \(reason)"
            case .untrustedServer: return "Something else is answering on the channel. Nothing was sent."
            case .transport: return "The app stopped answering partway through."
            case .unsupportedVersion: return "The app and this extension are different versions."
            }
        case .failure:
            return "The channel could not be opened."
        }
    }

    /// The host's own Cancel is not guaranteed to be on screen, so the sheet
    /// carries one: a provider that cannot serve a credential must still leave
    /// the user a way out.
    @objc private func cancel() {
        extensionContext.cancelRequest(withError: ASExtensionError(.userCanceled))
    }
}
