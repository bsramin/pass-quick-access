// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Security

/// Where the app and the credential provider meet, and how each decides the
/// other is who it claims to be.
///
/// The extension is sandboxed, as the system requires of a credential provider,
/// so it cannot run `pass-cli` and does not try: it asks over this channel and
/// the app answers. That keeps one process in charge of the CLI, which matters
/// more than tidiness. `pass-cli` keeps a single session on disk and rotates its
/// refresh token on use, so a second process reading vaults would rotate the
/// first one's token out and sign the user out; see `SessionLock`.
///
/// Nothing here names a team or a bundle identifier literally. Both are read
/// from this build's own signature, so a fork signing with its own account needs
/// no change. It also means an unsigned build resolves to nothing and the
/// channel never opens, which is the right answer rather than a shortcoming: an
/// unsigned build cannot carry the app-group entitlement the socket lives behind
/// either.
enum AutoFillChannel {
    /// Appended to the team identifier to name the shared container. Kept to
    /// three characters because the socket inside it has to fit in `sun_path`'s
    /// 104 bytes, and every character here is one fewer available to a user's
    /// home directory path.
    private static let groupSuffix = "pqa"
    /// What the extension's bundle identifier adds to the app's.
    static let extensionBundleSuffix = ".AutoFill"
    private static let socketName = "af.sock"

    /// The team this build is signed with, or nil when it carries no team, which
    /// is the case for an ad-hoc signature.
    static let teamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let running = code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &staticCode) == errSecSuccess,
              let onDisk = staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(onDisk, flags, &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
    }()

    /// The app's identifier, whichever side is asking: the extension's own ends
    /// in the suffix, so it is stripped when present.
    static var appBundleIdentifier: String? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        guard identifier.hasSuffix(extensionBundleSuffix) else { return identifier }
        return String(identifier.dropLast(extensionBundleSuffix.count))
    }

    static var extensionBundleIdentifier: String? {
        appBundleIdentifier.map { $0 + extensionBundleSuffix }
    }

    static var groupIdentifier: String? {
        teamIdentifier.map { "\($0).\(groupSuffix)" }
    }

    /// The socket both sides use, inside the group container. Nil when the build
    /// carries no team or the container is unreachable, which is what an
    /// unentitled build sees.
    static var socketPath: String? {
        guard let group = groupIdentifier,
              let container = FileManager.default
                  .containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appendingPathComponent(socketName).path
    }

    /// The identity `CodeSignatureCheck` reports for the extension, for the app
    /// to check its caller against.
    static var expectedExtensionIdentity: String? {
        guard let team = teamIdentifier, let identifier = extensionBundleIdentifier else { return nil }
        return "team:\(team):\(identifier)"
    }

    /// The identity the app should present, for the extension to check the
    /// server against. Squatting the socket already requires the same app-group
    /// entitlement, so this is a second lock on the same door rather than the
    /// only one; it is cheap, and it means a record identifier is never handed
    /// to something that merely got there first.
    static var expectedAppIdentity: String? {
        guard let team = teamIdentifier, let identifier = appBundleIdentifier else { return nil }
        return "team:\(team):\(identifier)"
    }
}
