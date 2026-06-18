// SPDX-License-Identifier: GPL-3.0-only

import Foundation

enum SSHAgentStatus: Equatable, Sendable {
    case off
    case starting
    case running
    case upstreamUnavailable
    case failed(String)

    var label: String {
        switch self {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .upstreamUnavailable: return "Waiting for the pass-cli agent"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

/// Owns the SSH agent proxy's lifecycle: it starts the upstream `pass-cli` agent,
/// binds the proxy socket, and tears everything down when disabled. The
/// remembered-decisions store is exposed so Settings can manage it.
@MainActor
final class AgentProxyController: ObservableObject {
    @Published private(set) var status: SSHAgentStatus = .off

    let store = RememberedDecisionsStore()

    private let executable: URL
    private let infoCoordinator = SignInfoCoordinator()
    private var listener: AgentSocketListener?

    /// Debounce for `autoRecover`, so a flurry of failed signatures restarts the
    /// daemon once rather than repeatedly.
    private var isAutoRecovering = false
    private var lastAutoRecover: Date?
    private let autoRecoverCooldown: TimeInterval = 5

    init(executable: URL, reconnector: PATReconnector? = nil) {
        self.executable = executable
        // After an SSH approval, reuse that Touch ID to restore a dropped session
        // before the signature is forwarded. Session only, never an agent restart:
        // the relay's upstream connection is mid-request.
        infoCoordinator.onAuthenticated = { [weak reconnector] context in
            await reconnector?.restoreSessionIfNeeded(using: context)
        }
    }

    var proxySocketPath: String {
        UnixSocket.expand(UnixSocket.defaultProxyPath)
    }

    func start() async {
        guard listener == nil else { return }
        status = .starting

        let upstreamPath = configuredUpstreamPath()
        let daemon = UpstreamDaemonManager(
            executable: executable,
            socketPath: upstreamPath,
            vaultFilter: vaultFilter()
        )
        let upstreamReady = await daemon.ensureRunning()

        let authorizer = SignAuthorizer(store: store, presenter: SignInfoPresenter(coordinator: infoCoordinator))
        let proxy = AgentRelay(
            upstreamPath: upstreamPath,
            authorizer: authorizer,
            keyNameCache: KeyLabelCache(),
            identifier: ProcessInspector(),
            onUpstreamFailure: { [weak self] in
                Task { @MainActor in self?.autoRecover() }
            }
        )

        let listener = AgentSocketListener(path: UnixSocket.defaultProxyPath) { fd in
            proxy.handle(clientFD: fd)
        }
        do {
            try listener.start()
        } catch {
            status = .failed(String(describing: error))
            return
        }
        self.listener = listener
        status = upstreamReady ? .running : .upstreamUnavailable

        if UserDefaults.standard.bool(forKey: SettingKey.sshSetEnvVar) {
            setSessionSocket(true)
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
        status = .off
        setSessionSocket(false)
    }

    /// Brings the agent back after the `pass-cli` session was restored. A logged-out
    /// session leaves the upstream daemon unable to serve keys, so this restarts it;
    /// if the proxy itself isn't up yet (agent enabled mid-session) it starts fresh.
    /// The restart is unconditional: the daemon's socket often still answers while
    /// it serves keys from the now-stale session, so just checking reachability
    /// would leave signatures broken.
    func recover() async {
        guard UserDefaults.standard.bool(forKey: SettingKey.sshAgentEnabled) else { return }
        guard listener != nil else {
            await start()
            return
        }
        await restartDaemon()
    }

    /// Restarts the upstream daemon in the background when the relay reports that a
    /// signature failed or the daemon is unreachable. This heals a daemon left on a
    /// stale session without the user toggling the agent off and on. Debounced, so a
    /// burst of failed signatures triggers a single restart rather than a storm.
    private func autoRecover() {
        guard UserDefaults.standard.bool(forKey: SettingKey.sshAgentEnabled), listener != nil else { return }
        guard !isAutoRecovering else { return }
        if let last = lastAutoRecover, Date().timeIntervalSince(last) < autoRecoverCooldown { return }
        isAutoRecovering = true
        lastAutoRecover = Date()
        Task {
            await restartDaemon()
            isAutoRecovering = false
        }
    }

    private func restartDaemon() async {
        status = .starting
        let daemon = UpstreamDaemonManager(
            executable: executable,
            socketPath: configuredUpstreamPath(),
            vaultFilter: vaultFilter()
        )
        status = await daemon.restart() ? .running : .upstreamUnavailable
    }

    /// Applies the "set SSH_AUTH_SOCK" toggle immediately.
    func applyEnvVarSetting() {
        setSessionSocket(UserDefaults.standard.bool(forKey: SettingKey.sshSetEnvVar) && listener != nil)
    }

    /// Publishes (or clears) `SSH_AUTH_SOCK` for the login session through
    /// `launchctl`, so newly launched programs inherit the proxy socket.
    private func setSessionSocket(_ on: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = on
            ? ["setenv", "SSH_AUTH_SOCK", proxySocketPath]
            : ["unsetenv", "SSH_AUTH_SOCK"]
        try? process.run()
    }

    /// Re-applies the enabled setting: start when on, stop when off.
    func applyEnabledSetting() async {
        let enabled = UserDefaults.standard.bool(forKey: SettingKey.sshAgentEnabled)
        if enabled {
            await start()
        } else {
            stop()
        }
    }

    private func configuredUpstreamPath() -> String {
        let override = UserDefaults.standard.string(forKey: SettingKey.sshUpstreamSocketPath)
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        return UnixSocket.defaultUpstreamPath
    }

    private func vaultFilter() -> String? {
        UserDefaults.standard.string(forKey: SettingKey.sshVaultFilter)?
            .trimmingCharacters(in: .whitespaces)
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
