// SPDX-License-Identifier: GPL-3.0-only

import AuthenticationServices
import Foundation

/// The list macOS needs in order to name your logins in the AutoFill menu.
///
/// Everything else this app does keeps its index in memory and nowhere else.
/// This does not: a suggestion the system draws before the extension has been
/// asked for anything has to come from something the system already holds, so
/// turning it on saves each login's site and username, plus an opaque reference
/// to the item, into the password database macOS manages. Never a password,
/// never a one-time code, and never a note, URL path or anything else from the
/// item.
///
/// It is off by default and it is the only thing in the app that writes outside
/// its own memory, which is why the switch explains itself and why SECURITY.md
/// calls it out by name. Turning it off removes what was written.
@MainActor
enum AutoFillSuggestions {
    /// Replaces the stored list with what the index currently holds. Called
    /// after a full pass over the vaults, so the list tracks the vault rather
    /// than drifting from it.
    static func publish(_ items: [ItemSummary], rank: (ItemSummary.ID) -> Int = { _ in 0 }) {
        guard UserDefaults.standard.bool(forKey: SettingKey.autofillSuggestionList) else { return }

        var identities: [any ASCredentialIdentity] = []
        for item in items {
            // A login with nothing to call the user by would appear as a blank
            // row, and macOS would fill that blank into the username field.
            // Better absent from the menu than wrong in the form.
            guard let account = item.account else { continue }
            for host in coveringHosts(of: item) {
                let service = ASCredentialServiceIdentifier(identifier: host, type: .domain)
                if item.hasPassword {
                    let identity = ASPasswordCredentialIdentity(
                        serviceIdentifier: service,
                        user: account,
                        recordIdentifier: item.id
                    )
                    identity.rank = rank(item.id)
                    identities.append(identity)
                }
                if item.hasTOTP, #available(macOS 15.0, *) {
                    let identity = ASOneTimeCodeCredentialIdentity(
                        serviceIdentifier: service,
                        label: account,
                        recordIdentifier: item.id
                    )
                    identity.rank = rank(item.id)
                    identities.append(identity)
                }
            }
        }

        replace(with: identities)
    }

    /// The hosts to register an item under: its own, minus any that a broader
    /// one already covers.
    ///
    /// One row per URL meant a login saved against google.com,
    /// accounts.google.com and myaccount.google.com appeared in the menu three
    /// times over, identical but for the domain under the username. macOS
    /// matches within a site itself, so the broader entry is offered on the
    /// subdomains anyway. Duplicate URLs collapse here too, since two of them
    /// reduce to the same host as often as not.
    static func coveringHosts(of item: ItemSummary) -> [String] {
        let hosts = Set(item.urls.compactMap(WebHost.from))
        return hosts
            .filter { host in !hosts.contains { host.hasSuffix("." + $0) } }
            .sorted()
    }

    /// Removes everything, for when the switch goes off, the provider is turned
    /// off in System Settings, or the index is dropped because the session went.
    /// Left behind, the list would name logins from a vault nobody can reach.
    static func clear() {
        Task { try? await ASCredentialIdentityStore.shared.removeAllCredentialIdentities() }
    }

    /// The store refuses writes while the provider is off in System Settings, so
    /// its state is checked rather than the error being swallowed. A failure is
    /// not worth interrupting anyone over: the extension still works, its
    /// entries just aren't named in the menu.
    private static func replace(with identities: [any ASCredentialIdentity]) {
        Task { @MainActor in
            guard await ASCredentialIdentityStore.shared.state().isEnabled else { return }
            // A failure here costs the menu its names and nothing else, so it
            // is swallowed rather than surfaced: the extension still answers,
            // and there is no action to offer the user anyway.
            try? await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
        }
    }
}
