// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import XCTest
@testable import PassQuickAccess

/// The encrypted copy of the index that lets a launch answer before `pass-cli`
/// has been run. Everything here is about what survives a restart and, just as
/// much, what deliberately doesn't.
final class IndexCacheTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/dev/null")
    private let key = Data(repeating: 0xAB, count: 32)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-cache-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeCache(key: Data? = nil, schemaVersion: Int? = nil) -> IndexCache {
        IndexCache(
            url: directory.appendingPathComponent("index.sealed"),
            key: key ?? self.key,
            schemaVersion: schemaVersion ?? IndexCache.currentSchemaVersion
        )
    }

    private func makeItem(
        id: String = "i1",
        title: String = "GitHub",
        note: String? = nil,
        customFields: [String] = []
    ) -> ItemSummary {
        ItemSummary(
            itemID: id,
            shareID: "s1",
            vaultName: "Personal",
            title: title,
            username: "user",
            email: "user@example.com",
            urls: ["https://github.com/login"],
            note: note,
            customFields: customFields,
            modifyTime: "2026-01-01T00:00:00",
            hasPassword: true,
            hasTOTP: true
        )
    }

    func testASavedIndexComesBackWithTheRowsItHeld() throws {
        let cache = makeCache()
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)

        try cache.save([makeItem(), makeItem(id: "i2", title: "Fastmail")], at: savedAt)
        let restored = cache.load()

        XCTAssertEqual(restored?.items.map(\.title), ["GitHub", "Fastmail"])
        XCTAssertEqual(restored?.savedAt, savedAt)
        let first = try XCTUnwrap(restored?.items.first)
        XCTAssertEqual(first.id, "s1/i1")
        XCTAssertEqual(first.account, "user")
        XCTAssertEqual(first.urls, ["https://github.com/login"])
        XCTAssertEqual(first.vaultName, "Personal")
        XCTAssertEqual(first.modifyTime, "2026-01-01T00:00:00")
        XCTAssertTrue(first.hasPassword)
        XCTAssertTrue(first.hasTOTP)
    }

    func testNothingSavedMeansNothingToRestore() {
        XCTAssertNil(makeCache().load(), "a first launch has no cache and must not be an error")
    }

    func testNotesAndCustomFieldsAreNeverWrittenDown() throws {
        let cache = makeCache()
        try cache.save(
            [makeItem(note: "recovery code 8842", customFields: ["Licence", "XK-99"])],
            at: Date()
        )

        let restored = try XCTUnwrap(cache.load()?.items.first)

        // A note is the one field people paste secrets into, so it stays in
        // memory and comes back with the first refresh instead of living on disk.
        XCTAssertNil(restored.note)
        XCTAssertEqual(restored.customFields, [])
    }

    func testAnIndexSealedWithAnotherKeyIsRefused() throws {
        try makeCache().save([makeItem()], at: Date())

        let other = makeCache(key: Data(repeating: 0xCD, count: 32))

        XCTAssertNil(other.load(), "a key that cannot open the file must read as no cache at all")
    }

    func testATamperedIndexIsRefused() throws {
        let url = directory.appendingPathComponent("index.sealed")
        let cache = makeCache()
        try cache.save([makeItem()], at: Date())

        var sealed = try Data(contentsOf: url)
        sealed[sealed.count - 1] ^= 0xFF
        try sealed.write(to: url)

        XCTAssertNil(cache.load(), "an authenticated payload must not survive an edited byte")
    }

    func testAnIndexFromAnEarlierSchemaIsRefused() throws {
        try makeCache(schemaVersion: IndexCache.currentSchemaVersion - 1).save([makeItem()], at: Date())

        XCTAssertNil(makeCache().load(), "a renamed or re-shaped row must not be read as the current one")
    }

    func testTheSealedIndexIsReadableByItsOwnerAlone() throws {
        let cache = makeCache()
        try cache.save([makeItem()], at: Date())

        let file = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("index.sealed").path
        )
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)

        XCTAssertEqual(file[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        XCTAssertEqual(folder[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testTheSealedIndexIsKeptOutOfBackups() throws {
        let cache = makeCache()
        try cache.save([makeItem()], at: Date())

        let file = directory.appendingPathComponent("index.sealed")
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])

        XCTAssertEqual(values.isExcludedFromBackup, true, "a device-bound cache has no business in a backup")
    }

    func testRemovingTheCacheLeavesNothingBehind() throws {
        let cache = makeCache()
        try cache.save([makeItem()], at: Date())

        cache.remove()

        XCTAssertNil(cache.load())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.sealed").path),
            "signing out should take the file with it, not just the ability to read it"
        )
    }
}
