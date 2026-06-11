// SPDX-License-Identifier: GPL-3.0-only

import Foundation

// JSON shapes track `pass-cli` 2.1.2 (`--output json`). Refresh them when the
// CLI changes its output.

struct VaultList: Decodable, Sendable {
    let vaults: [Vault]
}

/// A vault the signed-in user can read.
struct Vault: Identifiable, Hashable, Sendable, Decodable {
    let name: String
    let vaultID: String
    let shareID: String

    var id: String { shareID }

    private enum CodingKeys: String, CodingKey {
        case name
        case vaultID = "vault_id"
        case shareID = "share_id"
    }
}

/// Identifies an item for `view`/`totp` commands. Item IDs are only unique
/// within a share, so both halves are required.
struct ItemReference: Hashable, Sendable {
    let shareID: String
    let itemID: String
}

/// The searchable metadata for a login. Built by projecting a `DetailedItem`
/// down to non-secret fields; passwords and TOTP secrets are never carried
/// here; they are fetched fresh at fill time.
struct ItemSummary: Identifiable, Hashable, Sendable {
    let itemID: String
    let shareID: String
    let vaultName: String
    let title: String
    let username: String?
    let email: String?
    let urls: [String]
    /// The item's note, included in search but not shown in the row.
    let note: String?
    /// Custom-field text included in search: every field name, plus the value
    /// of text fields (never the value of hidden fields).
    let customFields: [String]
    /// ISO-8601 modification timestamp (fixed width, so it sorts chronologically
    /// as a plain string). Used to order results most-recent-first.
    let modifyTime: String
    /// Whether the item has a password / one-time code, so the copy action can
    /// be hidden when absent.
    let hasPassword: Bool
    let hasTOTP: Bool

    var id: String { "\(shareID)/\(itemID)" }

    var reference: ItemReference {
        ItemReference(shareID: shareID, itemID: itemID)
    }

    /// The account label to show under the title: username, or email as a
    /// fallback for items that only carry one.
    var account: String? { username ?? email }

    init(
        itemID: String,
        shareID: String,
        vaultName: String,
        title: String,
        username: String? = nil,
        email: String? = nil,
        urls: [String] = [],
        note: String? = nil,
        customFields: [String] = [],
        modifyTime: String = "",
        hasPassword: Bool = false,
        hasTOTP: Bool = false
    ) {
        self.itemID = itemID
        self.shareID = shareID
        self.vaultName = vaultName
        self.title = title
        self.username = username
        self.email = email
        self.urls = urls
        self.note = note
        self.customFields = customFields
        self.modifyTime = modifyTime
        self.hasPassword = hasPassword
        self.hasTOTP = hasTOTP
    }

    /// Fails for non-login items, which carry no `Login` payload.
    init?(_ item: DetailedItem, vault: Vault) {
        guard let login = item.content.typed.login else { return nil }
        itemID = item.id
        shareID = item.shareID
        vaultName = vault.name
        title = item.content.title
        username = login.username.nilIfBlank
        email = login.email.nilIfBlank
        urls = login.urls.filter { !$0.isEmpty }
        note = item.content.note.nilIfBlank
        customFields = item.content.extraFields.flatMap { field in
            [field.name, field.textValue].compactMap { $0?.nilIfBlank }
        }
        modifyTime = item.modifyTime
        hasPassword = !login.password.isEmpty
        hasTOTP = !login.totpURI.isEmpty
    }
}

struct ItemList: Decodable, Sendable {
    let items: [DetailedItem]
}

/// `item totp --output json` returns the generated code under `totp`.
struct TOTPResponse: Decodable, Sendable {
    let code: String

    private enum CodingKeys: String, CodingKey {
        case code = "totp"
    }
}

/// One item as returned by `item list --show-secrets`.
struct DetailedItem: Decodable, Sendable {
    let id: String
    let shareID: String
    let vaultID: String
    let modifyTime: String
    let content: ItemContent

    private enum CodingKeys: String, CodingKey {
        case id
        case shareID = "share_id"
        case vaultID = "vault_id"
        case modifyTime = "modify_time"
        case content
    }

    struct ItemContent: Decodable, Sendable {
        let title: String
        let note: String
        let extraFields: [ExtraField]
        let typed: TypedContent

        private enum CodingKeys: String, CodingKey {
            case title
            case note
            case extraFields = "extra_fields"
            case typed = "content"
        }
    }

    /// A custom field: `{ "name": ..., "content": { "Text": ... } }`. The value
    /// is kept only for text fields; hidden fields expose `{ "Hidden": ... }`,
    /// whose value stays out of the index.
    struct ExtraField: Decodable, Sendable {
        let name: String
        let textValue: String?

        private enum CodingKeys: String, CodingKey {
            case name, content
        }

        private enum ContentKeys: String, CodingKey {
            case text = "Text"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            let content = try? container.nestedContainer(keyedBy: ContentKeys.self, forKey: .content)
            textValue = try content?.decodeIfPresent(String.self, forKey: .text) ?? nil
        }
    }

    /// The protobuf content oneof, e.g. `{ "Login": { … } }`. Only the login
    /// case is modelled; other item types decode to `nil`.
    struct TypedContent: Decodable, Sendable {
        let login: LoginContent?

        private enum CodingKeys: String, CodingKey {
            case login = "Login"
        }
    }

    struct LoginContent: Decodable, Sendable {
        let email: String
        let username: String
        let urls: [String]
        let password: String
        let totpURI: String

        private enum CodingKeys: String, CodingKey {
            case email, username, urls, password
            case totpURI = "totp_uri"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
