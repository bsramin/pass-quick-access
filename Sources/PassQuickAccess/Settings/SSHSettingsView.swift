// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Settings for the SSH agent proxy, split into sub-tabs: the enable toggle and
/// status, how to point clients at the proxy, the upstream/vault options, and the
/// remembered approval decisions. The sub-tabs appear once the agent is enabled.
struct SSHSettingsView: View {
    @ObservedObject var controller: AgentProxyController

    @AppStorage(SettingKey.sshAgentEnabled) private var enabled = false
    @AppStorage(SettingKey.sshVaultFilter) private var vaultFilter = ""
    @AppStorage(SettingKey.sshUpstreamSocketPath) private var upstreamPath = ""
    @AppStorage(SettingKey.sshSetEnvVar) private var setEnvVar = false
    @AppStorage(SettingKey.sshRememberApprovedApps) private var rememberApps = false

    @State private var decisions: [RememberedSignDecision] = []
    @State private var configInstalled = SSHConfigInstaller.isInstalled()
    @State private var configError: String?
    @State private var block: Block = .agent

    enum Block: String, CaseIterable, Identifiable {
        case agent, setup, advanced, trusted
        var id: String { rawValue }
        var title: String {
            switch self {
            case .agent: return "Agent"
            case .setup: return "Setup"
            case .advanced: return "Advanced"
            case .trusted: return "Trusted Apps"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if blocks.count > 1 {
                SubTabBar(selection: $block, tabs: blocks, title: \.title)
            }
            Form {
                switch block {
                case .agent: agent
                case .setup: setup
                case .advanced: advanced
                case .trusted: trusted
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: enabled) { _, _ in
            if !blocks.contains(block) { block = .agent }
        }
        .task(id: enabled) {
            await controller.applyEnabledSetting()
            await reloadDecisions()
        }
        .onChange(of: setEnvVar) { _, _ in
            controller.applyEnvVarSetting()
        }
    }

    /// Only the Agent block until the agent is on; the rest configure a running one.
    private var blocks: [Block] {
        enabled ? Block.allCases : [.agent]
    }

    @ViewBuilder
    private var agent: some View {
        Section {
            Toggle("Enable SSH agent", isOn: $enabled)
            LabeledContent("Status", value: controller.status.label)
                .foregroundStyle(.secondary)
        } footer: {
            Text("Serves your Proton Pass SSH keys to git and ssh, and asks for Touch ID before each signature. Keys stay inside pass-cli; this app never sees them.")
        }
    }

    @ViewBuilder
    private var setup: some View {
        Section {
            Toggle("Configure ~/.ssh/config automatically", isOn: Binding(
                get: { configInstalled },
                set: { install in updateConfig(install: install) }
            ))
            Toggle("Set SSH_AUTH_SOCK for new programs", isOn: $setEnvVar)
            if let configError {
                Text(configError).font(.caption).foregroundStyle(.red)
            }
        } footer: {
            Text("The config entry makes ssh and git use the proxy with no environment variable. The SSH_AUTH_SOCK option also covers tools that read the variable instead of ~/.ssh/config (takes effect for programs launched afterwards).")
        }
    }

    @ViewBuilder
    private var advanced: some View {
        Section {
            TextField("Vault name (optional)", text: $vaultFilter)
            TextField("Upstream socket (advanced)", text: $upstreamPath, prompt: Text("~/.ssh/proton-pass-agent.sock"))
        } footer: {
            Text("Leave the vault empty to serve keys from every vault. Changes take effect next time the agent starts.")
        }
    }

    @ViewBuilder
    private var trusted: some View {
        Section {
            Toggle("Stop asking after I approve an app", isOn: $rememberApps)
            if decisions.isEmpty {
                Text("No trusted apps yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(decisions) { decision in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(decision.appName)
                            Text(decision.allow ? "Always allow" : "Always deny")
                                .font(.caption)
                                .foregroundStyle(decision.allow ? .green : .red)
                            + Text(decision.keyName.map { " · \($0)" } ?? " · any key")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") {
                            Task {
                                await controller.store.forget(id: decision.id)
                                await reloadDecisions()
                            }
                        }
                    }
                }
            }
        } footer: {
            Text("With the toggle on, an app you approve is trusted and won't ask again. Forgetting one makes it prompt next time. Either way, repeated signatures within a few seconds aren't re-prompted.")
        }
    }

    private func reloadDecisions() async {
        decisions = await controller.store.all()
    }

    private func updateConfig(install: Bool) {
        configError = nil
        do {
            if install {
                try SSHConfigInstaller.install()
            } else {
                try SSHConfigInstaller.uninstall()
            }
            configInstalled = SSHConfigInstaller.isInstalled()
        } catch {
            configError = "Couldn't update ~/.ssh/config: \(error.localizedDescription)"
        }
    }
}
