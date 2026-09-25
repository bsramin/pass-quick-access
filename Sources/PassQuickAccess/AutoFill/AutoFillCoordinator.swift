// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Owns the AutoFill server's lifetime. Same shape as `AgentProxyController`,
/// which has had `applyEnabledSetting` for as long as the SSH agent has had a
/// switch; the server used to start at launch and never again, so the setting
/// only took effect on the next one.
@MainActor
final class AutoFillCoordinator: ObservableObject {
    /// Why the server isn't running when it should be.
    @Published private(set) var failure: String?

    private let client: PassCLIClient
    private let controller: QuickAccessController
    private var server: AutoFillServer?

    init(client: PassCLIClient, controller: QuickAccessController) {
        self.client = client
        self.controller = controller
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingKey.autofillProviderEnabled)
    }

    /// Brings the server in line with the setting. Safe to call repeatedly: it
    /// starts only what isn't running and stops only what is.
    func applyEnabledSetting() {
        guard isEnabled else {
            stop()
            return
        }
        guard server == nil else { return }
        start()
    }

    /// Starts the server if it should be running and isn't, and rebinds it if
    /// its socket no longer reaches it. Called on the wake URL, which the
    /// extension opens when it finds nobody listening.
    func ensureServing() {
        guard isEnabled else { return }
        if let server, server.isReachable { return }
        stop()
        start()
    }

    func stop() {
        server?.stop()
        server = nil
        failure = nil
    }

    /// A nil socket path means a build with no team, whose extension the system
    /// never offers either. Not a failure to report, so it doesn't set one.
    private func start() {
        guard let path = AutoFillChannel.socketPath else { return }
        let server = AutoFillServer(
            client: client,
            index: controller.viewModel,
            unlockWindow: controller.unlockWindow,
            socketPath: path
        )
        do {
            try server.start()
            self.server = server
            failure = nil
        } catch {
            let reason = (error as? UnixSocket.Failure)?.description ?? String(describing: error)
            NSLog("AutoFill server could not start: \(reason)")
            failure = reason
        }
    }
}
