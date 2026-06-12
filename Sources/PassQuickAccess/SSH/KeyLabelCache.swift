// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Maps a key fingerprint to the human comment the agent reported for it, so the
/// approval prompt can say "Personal GitHub key" instead of a raw blob. Filled by
/// snooping `identitiesAnswer` responses as they pass through the proxy.
actor KeyLabelCache {
    private var namesByFingerprint: [String: String] = [:]

    func update(with identities: [SSHIdentitiesAnswer.Identity]) {
        for identity in identities where !identity.comment.isEmpty {
            namesByFingerprint[SSHKeyFingerprint.of(identity.keyBlob)] = identity.comment
        }
    }

    func name(for fingerprint: String) -> String? {
        namesByFingerprint[fingerprint]
    }
}
