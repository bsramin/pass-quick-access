// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Security

/// The connecting program's identity, used as the key for remembered decisions
/// and the session cache. It's anchored to an Apple-signed tool or a real Team ID,
/// never the bare signing identifier (which an ad-hoc binary could spoof). An
/// unanchored peer is `unverified` and never auto-allowed.
struct VerifiedPeer: Sendable, Equatable {
    /// A forge-resistant identity such as `platform:com.apple.ssh` or
    /// `team:2BUA8C4S2C:com.agilebits...`, or `nil` when the peer couldn't be
    /// anchored to a trustworthy signature.
    let identity: String?

    var isVerified: Bool { identity != nil }

    static let unverified = VerifiedPeer(identity: nil)
}

/// Verifies the peer of a connected Unix socket via its audit token and the code
/// signing services. Any failure degrades to `.unverified` rather than throwing,
/// so a hardened proxy never treats an unverifiable peer as trusted.
enum CodeSignatureCheck {
    static func verify(fd: Int32) -> VerifiedPeer {
        guard let token = auditToken(of: fd) else { return .unverified }

        let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let dynamicCode = code else { return .unverified }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
              let onDisk = staticCode else { return .unverified }

        // The on-disk code must validate (intact signature) before we read it.
        guard SecStaticCodeCheckValidity(onDisk, [], nil) == errSecSuccess else { return .unverified }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(onDisk, flags, &information) == errSecSuccess,
              let info = information as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              !identifier.isEmpty else { return .unverified }

        let team = info[kSecCodeInfoTeamIdentifier as String] as? String

        // The signing identifier alone is attacker-controllable: anyone can
        // ad-hoc sign a binary claiming identifier "git" to inherit git's
        // remembered approval. Anchor trust to something only Apple can vouch for.
        //
        // Apple's own tools (/usr/bin/ssh, git from the CLT, …) are signed by
        // Apple with no Team ID; "anchor apple" matches exactly those.
        if satisfies(onDisk, requirement: "anchor apple") {
            return VerifiedPeer(identity: "platform:\(identifier)")
        }
        // Third-party code must chain to Apple (Developer ID / App Store) *and*
        // carry a Team ID. The Apple-chain check is essential: without it a
        // self-signed certificate could claim any Team ID it likes.
        if let team, !team.isEmpty, satisfies(onDisk, requirement: "anchor apple generic") {
            return VerifiedPeer(identity: "team:\(team):\(identifier)")
        }
        return .unverified
    }

    /// Whether the on-disk code validates against a code-signing requirement.
    private static func satisfies(_ code: SecStaticCode, requirement: String) -> Bool {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
              let parsed else { return false }
        return SecStaticCodeCheckValidity(code, [], parsed) == errSecSuccess
    }

    private static func auditToken(of fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, pointer, &length)
        }
        guard result == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return token
    }
}
