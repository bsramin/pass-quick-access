// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Cross-process advisory lock guarding the shared `pass-cli` session.
///
/// `pass-cli` keeps a single session on disk (`~/Library/Application
/// Support/proton-pass-cli/.session`), and Proton rotates that session's refresh
/// token on use. The rotation isn't atomic across processes: when two `pass-cli`
/// processes run at once they refresh against each other and rotate one another's
/// token out, dropping the session and forcing a re-login. The execution gate in
/// `PassCLIClient` only serialises calls inside this app; this lock extends that
/// across every process that takes it: the panel's client, the SSH daemon
/// (re)starts we spawn, and a `pass-cli` the user runs by hand.
///
/// It's an `flock` on a sidecar file next to the session. `flock` is owned by the
/// open file description, so two separate `open`s exclude each other even within
/// one process, giving in-process and cross-process serialisation from one
/// primitive. The long-lived `ssh-agent daemon`, once started, refreshes on its
/// own and can't take this lock; serialising every call we *do* spawn still
/// removes the collisions we cause.
enum SessionLock {
    /// A held lock. Releasing closes the descriptor, which drops the `flock`.
    struct Token: Sendable {
        fileprivate let descriptor: Int32
        func release() { close(descriptor) }
    }

    private static let defaultURL: URL? = {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support
            .appendingPathComponent("proton-pass-cli", isDirectory: true)
            .appendingPathComponent("session.lock", isDirectory: false)
    }()

    /// Acquires the shared session lock, to be released with `Token.release` once
    /// the pass-cli call finishes (pair it with a `defer`). Returns `nil` (so the
    /// caller proceeds, falling back to the in-app gate) when the lock file can't
    /// be opened, rather than stranding the user over a filesystem hiccup.
    static func acquire() async -> Token? {
        await acquire(at: defaultURL)
    }

    /// Acquires the lock at an explicit file, so tests can exercise it without
    /// touching the real session lock. Polls without parking a thread so the
    /// caller stays cancellable and the cooperative pool isn't blocked; contention
    /// here is rare and short.
    static func acquire(at url: URL?) async -> Token? {
        guard let url else { return nil }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }

        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return Token(descriptor: descriptor)
            }
            guard errno == EWOULDBLOCK else {
                close(descriptor)
                return nil
            }
            // Held elsewhere: wait briefly and retry, yielding to cancellation.
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                close(descriptor)
                return nil
            }
        }
    }
}
