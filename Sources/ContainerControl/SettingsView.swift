import ServiceManagement
import SwiftUI

enum Preferences {
    static let notifyAgentActions = "notifyAgentActions"
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.notifyAgentActions) private var notifyAgentActions = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Toggle("Open Container Control at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("It only opens the app. Your projects do not start by themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify me when an agent starts or stops a project", isOn: $notifyAgentActions)
                    .onChange(of: notifyAgentActions) { _, enabled in
                        if enabled { model.requestNotificationPermission() }
                    }
            }

            Section {
                Toggle("Open projects at http://<id>.localhost", isOn: Binding(
                    get: { model.proxy.installed },
                    set: { model.setDomains($0) }
                ))
                if model.proxy.installed {
                    if model.proxy.running {
                        Label("Working. Project index at http://localhost", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label(model.proxy.portTakenBy.map { "Port 80 is being used by \($0)." } ?? "The proxy is not running.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Domains")
            } footer: {
                Text("Each project gets its own domain, so the port it runs on stops mattering: if its port is taken, Container Control gives it a free one when it knows how. Only answers connections from this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Claude Code") {
                    Button("Copy Command") { copy(AgentSetup.claudeCode) }
                }
                LabeledContent("Claude Desktop, Cursor and others") {
                    Button("Copy JSON") { copy(AgentSetup.mcpJSON) }
                }
                if copied {
                    Text("Copied. Paste it in your terminal or in the client's MCP configuration.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Connect AI Agents")
            } footer: {
                Text("Agents with a terminal can also use the cctl command directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Command Line") {
                LabeledContent("cctl") {
                    Button("Install in ~/.local/bin") { model.installCLI() }
                }
                LabeledContent("Configuration") {
                    Button("Open Folder") { NSWorkspace.shared.open(model.service.paths.base) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .dockPresence()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Snippets to register `cctl mcp` with MCP clients, pointing at the cctl inside the app bundle.
enum AgentSetup {
    static var cctlPath: String {
        Bundle.main.url(forAuxiliaryExecutable: "cctl")?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cctl").path
    }

    static var claudeCode: String {
        "claude mcp add --scope user container-control -- \"\(cctlPath)\" mcp"
    }

    static var mcpJSON: String {
        """
        {
          "mcpServers": {
            "container-control": {
              "command": "\(cctlPath)",
              "args": ["mcp"]
            }
          }
        }
        """
    }
}
