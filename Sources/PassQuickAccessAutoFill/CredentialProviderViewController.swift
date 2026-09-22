// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import AuthenticationServices

/// The credential provider macOS loads when an app or Safari asks for a
/// password. A placeholder for now: it proves the bundle is registered, signed
/// and offered by the system, which is the whole question this spike answers.
///
/// It stays deliberately empty of logic. The extension is sandboxed and so can
/// never run `pass-cli` itself; when it grows up it will ask the app over the
/// shared container, and the app will stay the only process that touches the
/// CLI. That matters beyond tidiness: `pass-cli` keeps one session on disk and
/// rotates its token on use, so a second process reading vaults would log the
/// user out (see SessionLock in the app target).
final class CredentialProviderViewController: ASCredentialProviderViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 140))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let title = NSTextField(labelWithString: "Pass Quick Access")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let detail = NSTextField(labelWithString: "Filling isn't wired up yet.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [title, detail, cancel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    /// The system's own Cancel is not guaranteed to be on screen in every host,
    /// so the sheet carries one: without a way out, a provider that can't serve
    /// a credential leaves the user stuck in it.
    @objc private func cancel() {
        extensionContext.cancelRequest(withError: ASExtensionError(.userCanceled))
    }
}
