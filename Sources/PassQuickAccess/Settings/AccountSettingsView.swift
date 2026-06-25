// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Manages the optional Personal Access Token that lets the app reconnect to
/// Proton Pass on its own after a session expires. The token is held in the
/// Keychain; this screen stores or clears it, and can sign in with it right away.
struct AccountSettingsView: View {
    var reconnector: PATReconnector?

    @State private var hasToken = PATStore.hasToken()
    @State private var entry = ""
    @State private var errorMessage: String?
    @State private var signIn: SignInState = .idle
    @State private var signInError: String?
    @State private var showingCreateHelp = false

    private enum SignInState: Equatable {
        case idle, working, signedIn, failed
    }

    var body: some View {
        Form {
            Section {
                if hasToken {
                    Label("Access token saved", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    if reconnector != nil {
                        Button("Sign in now", action: signInFromKeychain)
                            .disabled(signIn == .working)
                    }
                    Button("Remove token", role: .destructive, action: removeToken)
                } else {
                    SecureField("pst_…::…", text: $entry)
                        .textFieldStyle(.roundedBorder)
                    Button("Save token", action: saveToken)
                        .disabled(!looksLikeToken)
                }
                signInStatus
                Button("How do I create a token?") { showingCreateHelp = true }
                    .buttonStyle(.link)
            } header: {
                Text("Stay signed in")
            } footer: {
                Text("""
                Optional. When your Proton Pass session expires, the app reconnects \
                with this token so the panel and SSH agent keep working, reusing the \
                next Touch ID you do. The token is stored in the Keychain; the app \
                asks for Touch ID before using it.
                """)
            }
        }
        .formStyle(.grouped)
        .alert("Couldn't save the token", isPresented: showingError) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showingCreateHelp) {
            CreateTokenHelp(commands: Self.createCommands) { showingCreateHelp = false }
        }
    }

    @ViewBuilder
    private var signInStatus: some View {
        switch signIn {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Signing in…").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        case .signedIn:
            Label("Signed in", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.system(size: 12))
        case .failed:
            Label(signInError ?? "Couldn't sign in with this token. Check it's valid and not expired.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    private var looksLikeToken: Bool {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("pst_") && trimmed.contains("::")
    }

    private var showingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func saveToken() {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try PATStore.save(SensitiveString(trimmed))
            entry = ""
            hasToken = true
        } catch {
            errorMessage = String(describing: error)
            return
        }
        // The user just provided the token and is present, so sign in directly
        // without re-reading the Keychain behind Touch ID.
        guard let reconnector else { return }
        signIn = .working
        Task {
            let failure = await reconnector.signIn(with: SensitiveString(trimmed))
            signInError = failure
            signIn = failure == nil ? .signedIn : .failed
        }
    }

    private func signInFromKeychain() {
        guard let reconnector else { return }
        signIn = .working
        Task {
            let failure = await reconnector.signInFromStore(reason: "sign in to Proton Pass")
            signInError = failure
            signIn = failure == nil ? .signedIn : .failed
        }
    }

    private func removeToken() {
        PATStore.remove()
        hasToken = false
        signIn = .idle
    }

    private static let createCommands = [
        """
        pass-cli personal-access-token create \\
          --name "Pass Quick Access" --expiration 6m
        """,
        """
        pass-cli personal-access-token access grant \\
          --personal-access-token-name "Pass Quick Access" \\
          --vault-name "SSH" --role viewer
        """,
    ]
}

/// The "Creating a token" help, shown as a sheet so each command is its own
/// monospaced, quoted block with its own copy button.
private struct CreateTokenHelp: View {
    let commands: [String]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Creating a token").font(.headline)

            Text("Run these in Terminal while signed in, scoped read-only to just the vault you need:")
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                CommandBlock(command: command)
            }

            Text("Paste the value the first command prints (it starts with pst_) into the field above. A viewer-scoped token can only read the vaults you grant it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// One command shown like a small terminal window: a dark body with a `$` prompt
/// and monospaced text, a title bar with the traffic-light dots, and a copy button.
private struct CommandBlock: View {
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(red: 1.00, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 1.00, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 0.20, green: 0.78, blue: 0.35)).frame(width: 11, height: 11)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? .green : Color(white: 0.75))
                }
                .buttonStyle(.plain)
                .help("Copy this command")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(white: 0.22))

            Text("$ \(command)")
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(Color(white: 0.92))
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.13))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
