// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

/// The SHA-256 fingerprint of an SSH key blob, as lowercase hex. Used as a stable
/// identifier for a key in caches and remembered decisions, since the blob itself
/// is long and binary.
enum SSHKeyFingerprint {
    static func of(_ keyBlob: Data) -> String {
        SHA256.hash(data: keyBlob).map { String(format: "%02x", $0) }.joined()
    }
}

/// A remembered authorization choice for a verified app, optionally scoped to a
/// single key. A decision with `fingerprint == nil` applies to every key the app
/// asks to use.
struct RememberedSignDecision: Codable, Sendable, Equatable, Identifiable {
    /// The verified signing identity of the app this decision is about.
    let identity: String
    /// A human label for that app, for the Settings list.
    let appName: String
    /// The key fingerprint this applies to, or `nil` for "any key".
    let fingerprint: String?
    /// A human label for the key, when scoped to one.
    let keyName: String?
    let allow: Bool
    let createdAt: Date

    var id: String { "\(identity)|\(fingerprint ?? "*")" }

    /// Whether this decision governs a request from `identity` for `fingerprint`.
    func matches(identity: String, fingerprint: String) -> Bool {
        guard self.identity == identity else { return false }
        return self.fingerprint == nil || self.fingerprint == fingerprint
    }
}
