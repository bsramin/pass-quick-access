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
        // A daemon can linger with its process alive and its socket gone, which
        // blocks a fresh `start` with "already running". Asking first is local and
        // near-free, and `start` clears a stale socket on its own.
        if await daemonState() != .stopped {
            _ = try? await run(["ssh-agent", "daemon", "stop"], timeout: .seconds(10))
        }

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

    /// What the daemon reports about itself. `unknown` (wording we don't know, or
    /// a pass-cli older than 2.3) keeps the caller's unconditional stop.
    enum DaemonState {
        case running, stopped, unknown
    }

    private func daemonState() async -> DaemonState {
        // No session lock: this reads a PID file and pokes a socket, nothing more.
        guard let result = try? await runner.run(
            executable: executable,
            arguments: ["ssh-agent", "daemon", "status"],
            timeout: .seconds(5)
        ), result.status == 0 else { return .unknown }
        return Self.state(fromStatus: String(decoding: result.stdout, as: UTF8.self))
    }

    /// Reads the state off the `daemon status` report. It has to come from the
    /// text: the command exits 0 whether the daemon is up or down.
    static func state(fromStatus output: String) -> DaemonState {
        let line = output.lowercased()
            .split(separator: "\n")
            .first { $0.contains("status:") }
        guard let line else { return .unknown }
        if line.contains("stopped") || line.contains("not running") { return .stopped }
        return line.contains("running") ? .running : .unknown
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
