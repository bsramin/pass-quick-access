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
    /// The deadline for reading one field, which always happens with the user
    /// waiting on it. Shorter than the rest: an index can be worth a long wait,
    /// a password the user asked for a moment ago is better answered with "try
    /// again" than with fifteen seconds of nothing.
    private let fieldTimeout: Duration
    private let decoder = JSONDecoder()

    /// Gate that lets only one `pass-cli` process run at a time. The actor alone
    /// can't guarantee this: every `execute` suspends on `await runner.run`, and
    /// the actor reenters there, so without the gate concurrent callers (an index
    /// fan-out, a prefetch, a TOTP read) spawn overlapping processes.
    private var isExecuting = false
    private var executionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        executable: URL,
        runner: ProcessRunning = SystemProcessRunner(),
        timeout: Duration = .seconds(15),
        fieldTimeout: Duration = .seconds(8)
    ) {
        self.executable = executable
        self.runner = runner
        self.timeout = timeout
        self.fieldTimeout = fieldTimeout
    }

    /// Verifies the stored session can reach the server. Throws a
    /// `PassCLIError` whose `isAuthenticationFailure` flags a re-login.
    ///
    /// `vault list` is the probe: one round trip that names the vaults and reads
    /// nothing inside them. It was `pass-cli test` until 2.2.4 dropped it.
    func verifySession() async throws {
        _ = try await execute(["vault", "list"])
    }

    /// Whether `pass-cli` currently has a usable session. Unlike `verifySession`
    /// this swallows the error, for callers polling to see when a login lands.
    func hasSession() async -> Bool {
        do {
            try await verifySession()
            return true
        } catch let error as PassCLIError where error.isUnsupportedCommand {
            // A pass-cli that doesn't know the probe has told us nothing about
            // the session. Answering "gone" would send every caller off to
            // reconnect on a session that is fine, once per tick, forever.
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

    /// Streams the login index one vault at a time. Listing everything needs one
    /// `pass-cli item list` per vault (the command is always vault-scoped), and
    /// those run strictly one after another: in parallel they race each other's
    /// session-token refresh and drop the session out from under the user. Yielding
    /// a vault as soon as it's read lets the caller show its items immediately
    /// instead of blocking on all of them, which matters when there are many.
    nonisolated func indexLoginItems() -> AsyncThrowingStream<IndexedVault, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let vaults = try await self.vaults()
                    for (offset, vault) in vaults.enumerated() {
                        try Task.checkCancellation()
                        let items = try await self.loginItems(in: vault)
                        continuation.yield(IndexedVault(
                            vaultName: vault.name,
                            position: offset + 1,
                            total: vaults.count,
                            items: items
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
        ], timeout: fieldTimeout)
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
        ], timeout: fieldTimeout)
        return try string(from: output)
    }

    // MARK: - Command plumbing

    private func json<T: Decodable>(_ arguments: [String], timeout: Duration? = nil) async throws -> T {
        let result = try await execute(arguments, timeout: timeout)
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

    /// Runs one `pass-cli` command. `timeout` overrides the client's default for
    /// the commands the user is sitting in front of.
    private func execute(
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        await acquireExecutionSlot()
        defer { releaseExecutionSlot() }

        // Hold the cross-process session lock for the run, so this never overlaps
        // a pass-cli the SSH daemon manager or the user spawns and races its
        // session-token refresh. The in-app gate above only covers this client.
        let lock = await SessionLock.acquire()
        defer { lock?.release() }

        let result = try await runner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout ?? self.timeout
        )
        guard result.status == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            throw PassCLIError.commandFailed(status: result.status, stderr: stderr)
        }
        return result
    }

    /// Suspends until the single execution slot is free, so only one `pass-cli`
    /// process is ever in flight. Callers must pair this with `releaseExecutionSlot`.
    /// A waiting caller resumes only when the slot reaches it; a cancelled task
    /// still resumes there (the continuation is handed on exactly once) and its
    /// caller drops the result, so the queue can't stall.
    private func acquireExecutionSlot() async {
        guard isExecuting else {
            isExecuting = true
            return
        }
        await withCheckedContinuation { executionWaiters.append($0) }
    }

    /// Hands the slot to the next waiter, or marks it free when none are queued.
    private func releaseExecutionSlot() {
        if executionWaiters.isEmpty {
            isExecuting = false
        } else {
            executionWaiters.removeFirst().resume()
        }
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
