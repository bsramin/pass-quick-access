// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Settings for the SSH agent proxy: the enable toggle, the `~/.ssh/config`
/// snippet to point clients at it, the upstream/vault options, and the list of
/// remembered approval decisions.
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

    var body: some View {
        Form {
            Section {
                Toggle("Enable SSH agent", isOn: $enabled)
                LabeledContent("Status", value: controller.status.label)
                    .foregroundStyle(.secondary)
            } header: {
                Text("SSH Agent")
            } footer: {
                Text("Serves your Proton Pass SSH keys to git and ssh, and asks for Touch ID before each signature. Keys stay inside pass-cli; this app never sees them.")
            }

            if enabled {
                Section {
                    Toggle("Configure ~/.ssh/config automatically", isOn: Binding(
                        get: { configInstalled },
                        set: { install in updateConfig(install: install) }
                    ))
                    Toggle("Set SSH_AUTH_SOCK for new programs", isOn: $setEnvVar)
                    if let configError {
                        Text(configError).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Point SSH at it")
                } footer: {
                    Text("The config entry makes ssh and git use the proxy with no environment variable. The SSH_AUTH_SOCK option also covers tools that read the variable instead of ~/.ssh/config (takes effect for programs launched afterwards).")
                }

                Section {
                    TextField("Vault name (optional)", text: $vaultFilter)
                    TextField("Upstream socket (advanced)", text: $upstreamPath, prompt: Text("~/.ssh/proton-pass-agent.sock"))
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Leave the vault empty to serve keys from every vault. Changes take effect next time the agent starts.")
                }

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
                } header: {
                    Text("Trusted apps")
                } footer: {
                    Text("With the toggle on, an app you approve is trusted and won't ask again. Forgetting one makes it prompt next time. Either way, repeated signatures within a few seconds aren't re-prompted.")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: enabled) {
            await controller.applyEnabledSetting()
            await reloadDecisions()
        }
        .onChange(of: setEnvVar) { _, _ in
            controller.applyEnvVarSetting()
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
