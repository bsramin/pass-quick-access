// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Makes sure the upstream `pass-cli` SSH agent is running before the proxy needs
/// it. The proxy never holds keys itself; this just starts the agent that does,
/// pointed at a known socket path.
struct UpstreamDaemonManager: Sendable {
    let executable: URL
    let runner: ProcessRunning
    let socketPath: String
    /// Optional vault name to limit which vaults the agent serves keys from.
    let vaultFilter: String?

    init(
        executable: URL,
        socketPath: String,
        vaultFilter: String?,
        runner: ProcessRunning = SystemProcessRunner()
    ) {
        self.executable = executable
        self.socketPath = socketPath
        self.vaultFilter = vaultFilter
        self.runner = runner
    }

    /// Ensures the agent socket is reachable, starting the daemon if needed.
    /// Returns whether the socket is reachable when it finishes.
    func ensureRunning() async -> Bool {
        if isReachable() { return true }
        return await restart()
    }

    /// Stops and restarts the daemon unconditionally, even when its socket still
    /// answers. A reachable socket isn't enough after the `pass-cli` session has
    /// rotated: the daemon holds the old session in memory and keeps signing with
    /// it, so signatures fail ("Permission denied") until it's restarted with the
    /// current session. Returns whether the socket is reachable when it finishes.
    func restart() async -> Bool {
        // A daemon can linger in a "degraded" state (process alive, socket gone),
        // and that blocks a fresh `start` with "already running". Stop first so the
        // restart can recreate the socket; harmless when nothing is running.
        _ = try? await run(["ssh-agent", "daemon", "stop"], timeout: .seconds(10))

        var startArguments = ["ssh-agent", "daemon", "start", "--socket-path", UnixSocket.expand(socketPath)]
        if let vaultFilter, !vaultFilter.isEmpty {
            startArguments += ["--vault-name", vaultFilter]
        }
        _ = try? await run(startArguments, timeout: .seconds(20))

        // The daemon fetches keys from Proton before binding the socket, which can
        // take several seconds, so poll generously.
        for _ in 0..<48 {
            if isReachable() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return isReachable()
    }

    private func run(_ arguments: [String], timeout: Duration) async throws -> ProcessResult {
        // Take the shared session lock so a daemon start/stop, which reads and
        // rewrites the session, never races the panel's own pass-cli calls.
        let lock = await SessionLock.acquire()
        defer { lock?.release() }
        return try await runner.run(executable: executable, arguments: arguments, timeout: timeout)
    }

    private func isReachable() -> Bool {
        guard let fd = try? UnixSocket.connect(to: socketPath) else { return false }
        close(fd)
        return true
    }
}
