// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

/// An encrypted copy of the index, so a launch has rows to show before
/// `pass-cli` has been run even once.
struct IndexCache: Sendable {
    static let currentSchemaVersion = 1

    struct Snapshot: Sendable {
        let items: [ItemSummary]
        let savedAt: Date
    }

    private let url: URL
    private let key: Data
    private let schemaVersion: Int

    init(url: URL, key: Data, schemaVersion: Int = IndexCache.currentSchemaVersion) {
        self.url = url
        self.key = key
        self.schemaVersion = schemaVersion
    }

    /// The cache the app uses, or nil when the Keychain would not give up a
    /// key, in which case the app runs as it did before: index in memory, read
    /// from `pass-cli` at every launch.
    static func onDisk() -> IndexCache? {
        guard let key = IndexCacheKeyStore.key() else { return nil }
        return IndexCache(url: defaultFileURL(), key: key)
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PassQuickAccess", isDirectory: true)
            .appendingPathComponent("index.sealed")
    }

    func save(_ items: [ItemSummary], at savedAt: Date) throws {
        let payload = Payload(
            schemaVersion: schemaVersion,
            savedAt: savedAt,
            rows: items.map(Row.init)
        )
        let sealed = try AES.GCM.seal(
            try JSONEncoder().encode(payload),
            using: SymmetricKey(data: key)
        )
        guard let combined = sealed.combined else { throw CacheError.sealFailed }

        try prepareDirectory()
        try combined.write(to: url, options: .atomic)
        // An atomic write takes the mode from the temporary file it renames, so
        // the mode is set afterwards rather than assumed. The window that leaves
        // is inside a directory only the owner can open.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }

    func load() -> Snapshot? {
        guard let sealed = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key)),
              let payload = try? JSONDecoder().decode(Payload.self, from: plaintext),
              payload.schemaVersion == schemaVersion else {
            return nil
        }
        return Snapshot(items: payload.rows.map(\.summary), savedAt: payload.savedAt)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Makes sure the app's own directory under Application Support exists and
    /// is owner-only. It is tightened when it is already there, because it was
    /// first created by whichever store got there first and its mode is then
    /// whatever the umask said.
    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return
        }
        let attributes = try? manager.attributesOfItem(atPath: directory.path)
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        if mode != 0o700 {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private enum CacheError: Error {
        case sealFailed
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let rows: [Row]
    }

    /// Exactly what goes to disk: what a row shows, and what it is matched
    /// against. Notes and custom fields are searched but never written, so the
    /// field list here is the whole of the file's contents rather than an
    /// `ItemSummary` that happens to have some fields left empty.
    private struct Row: Codable {
        let itemID: String
        let shareID: String
        let vaultName: String
        let title: String
        let username: String?
        let email: String?
        let urls: [String]
        let modifyTime: String
        let hasPassword: Bool
        let hasTOTP: Bool

        init(_ item: ItemSummary) {
            itemID = item.itemID
            shareID = item.shareID
            vaultName = item.vaultName
            title = item.title
            username = item.username
            email = item.email
            urls = item.urls
            modifyTime = item.modifyTime
            hasPassword = item.hasPassword
            hasTOTP = item.hasTOTP
        }

        var summary: ItemSummary {
            ItemSummary(
                itemID: itemID,
                shareID: shareID,
                vaultName: vaultName,
                title: title,
                username: username,
                email: email,
                urls: urls,
                modifyTime: modifyTime,
                hasPassword: hasPassword,
                hasTOTP: hasTOTP
            )
        }
    }
}
