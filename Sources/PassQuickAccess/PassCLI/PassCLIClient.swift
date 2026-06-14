// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Thin, typed wrapper over the official Proton Pass CLI.
///
/// The client owns one design rule: secrets are never indexed or cached. Vault
/// and item *metadata* are read as JSON for searching; passwords and TOTP codes
/// are fetched one field at a time, on demand, and handed straight to the caller
/// as `SensitiveString`.
actor PassCLIClient {
    private let executable: URL
    private let runner: ProcessRunning
    private let timeout: Duration
    private let decoder = JSONDecoder()

    init(executable: URL, runner: ProcessRunning = SystemProcessRunner(), timeout: Duration = .seconds(15)) {
        self.executable = executable
        self.runner = runner
        self.timeout = timeout
    }

    /// Verifies the stored session can reach the server. Throws a
    /// `PassCLIError` whose `isAuthenticationFailure` flags a re-login.
    func verifySession() async throws {
        _ = try await execute(["test"])
    }

    /// Whether `pass-cli` currently has a usable session. Unlike `verifySession`
    /// this swallows the error, for callers polling to see when a login lands.
    func hasSession() async -> Bool {
        do {
            try await verifySession()
            return true
        } catch {
            return false
        }
    }

    /// Establishes a session from a Personal Access Token. The token is handed to
    /// `pass-cli login` through the environment, never as an argument, so it can't
    /// be read from another process's view of the command line.
    func login(withPAT token: SensitiveString) async throws {
        let environment = ["PROTON_PASS_PERSONAL_ACCESS_TOKEN": token.reveal()]
        Self.ensureSessionDirectory()
        do {
            _ = try await execute(["login"], environment: environment)
        } catch let error as PassCLIError where error.isCorruptLocalSession {
            // A stale, undecryptable local session (e.g. left by a forced logout)
            // blocks login before the token is tried. Clear it and retry once, as
            // pass-cli itself recommends.
            _ = try? await execute(["logout", "--force"])
            Self.ensureSessionDirectory()
            _ = try await execute(["login"], environment: environment)
        }
    }

    /// pass-cli's `logout` deletes its session directory, and a token login then
    /// fails to recreate it ("No such file or directory" while writing the
    /// session). Recreate it first so the login can persist.
    private static func ensureSessionDirectory() {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let directory = support.appendingPathComponent("proton-pass-cli/.session", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func vaults() async throws -> [Vault] {
        let response: VaultList = try await json(["vault", "list", "--output", "json"])
        return response.vaults
    }

    /// Builds the full login index by listing every vault concurrently. `item
    /// list` is always vault-scoped, so this is the only way to see everything.
    func indexLoginItems() async throws -> [ItemSummary] {
        let vaults = try await vaults()
        return try await withThrowingTaskGroup(of: [ItemSummary].self) { group in
            for vault in vaults {
                group.addTask { try await self.loginItems(in: vault) }
            }
            var items: [ItemSummary] = []
            for try await chunk in group {
                items.append(contentsOf: chunk)
            }
            return items
        }
    }

    /// Active login items in one vault, projected to metadata. `--show-secrets`
    /// is required because URLs and usernames live in the encrypted content; the
    /// decoder drops the secret fields it returns (see `DetailedItem`).
    func loginItems(in vault: Vault) async throws -> [ItemSummary] {
        let response: ItemList = try await json([
            "item", "list",
            "--share-id", vault.shareID,
            "--filter-type", "login",
            "--filter-state", "active",
            "--show-secrets",
            "--output", "json",
        ])
        return response.items.compactMap { ItemSummary($0, vault: vault) }
    }

    func password(for item: ItemReference) async throws -> SensitiveString {
        SensitiveString(try await field("password", of: item))
    }

    func totp(for item: ItemReference) async throws -> SensitiveString {
        let response: TOTPResponse = try await json([
            "item", "totp",
            "--share-id", item.shareID,
            "--item-id", item.itemID,
            "--output", "json",
        ])
        return SensitiveString(response.code)
    }

    /// Reads a single named field of a login item. The value is returned as raw
    /// text (no JSON envelope) so secret handling stays simple on the hot path.
    func field(_ name: String, of item: ItemReference) async throws -> String {
        let output = try await execute([
            "item", "view",
            "--share-id", item.shareID,
            "--item-id", item.itemID,
            "--field", name,
        ])
        return try string(from: output)
    }

    // MARK: - Command plumbing

    private func json<T: Decodable>(_ arguments: [String]) async throws -> T {
        let result = try await execute(arguments)
        do {
            return try decoder.decode(T.self, from: result.stdout)
        } catch {
            throw PassCLIError.malformedOutput(underlying: error)
        }
    }

    private func string(from result: ProcessResult) throws -> String {
        let text = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PassCLIError.emptyValue }
        return text
    }

    private func execute(_ arguments: [String], environment: [String: String]? = nil) async throws -> ProcessResult {
        let result = try await runner.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        guard result.status == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            throw PassCLIError.commandFailed(status: result.status, stderr: stderr)
        }
        return result
    }
}

extension PassCLIClient {
    /// Common install locations, ordered by how Proton documents them, plus a
    /// PATH scan. Returns the first executable found.
    static func locateExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        var candidates = [
            "\(NSHomeDirectory())/.local/bin/pass-cli",
            "/opt/homebrew/bin/pass-cli",
            "/usr/local/bin/pass-cli",
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/pass-cli" }
        }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}
