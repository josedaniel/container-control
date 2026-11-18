import AppKit
import ControlCore
import SwiftUI
import UniformTypeIdentifiers

/// Side panel to control and edit one project. Edits go to a draft and are saved explicitly.
struct ProjectInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let project: Project

    @State private var draft: Project
    @State private var envText: String
    @State private var confirmingRemove = false
    @State private var confirmingPublish = false
    @State private var logoTargeted = false

    init(project: Project) {
        self.project = project
        _draft = State(initialValue: project)
        _envText = State(initialValue: Self.envText(project.env))
    }

    private var isDirty: Bool { draft != project || Self.parseEnv(envText) != project.env }

    var body: some View {
        Form {
            header
            controls

            Section("General") {
                TextField("Name", text: $draft.name)
                LabeledContent("Domain") {
                    HStack(spacing: 2) {
                        TextField("Domain", text: hostnameBinding, prompt: Text(project.id))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        Text(".localhost").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Folder") {
                    HStack(spacing: 4) {
                        Text(project.shortPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button {
                            model.revealInFinder(project)
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
                Picker("Kind", selection: $draft.kind) {
                    ForEach(ProjectKind.allCases, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
                LabeledContent("ID") {
                    Text(project.id).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section {
                if draft.kind.usesLaunchd {
                    CodeField(label: "Start command", text: optional($draft.startCommand), prompt: "npm run dev")
                    CodeField(label: "Stop command", text: optional($draft.stopCommand), prompt: "Optional")
                }
                if draft.kind == .compose {
                    CodeField(label: "Compose file", text: optional($draft.composeFile), prompt: "compose.yaml")
                }
                TextField("Port", value: $draft.port, format: .number.grouping(.never), prompt: Text("None"))
            } header: {
                Text("Run")
            } footer: {
                Text(runFooter).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Variables", text: $envText, prompt: Text("KEY=value"), axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(2...8)
                    .labelsHidden()
            } header: {
                Text("Environment Variables")
            } footer: {
                Text("One per line, as KEY=value.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Permission", selection: $draft.agentPermission) {
                    ForEach(AgentPermission.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("AI Agents")
            } footer: {
                Text(permissionFooter).font(.caption).foregroundStyle(.secondary)
            }

            publishSection

            let recent = model.activity(for: project.id, limit: 5)
            if !recent.isEmpty {
                Section("Recent Activity") {
                    ForEach(recent.indices, id: \.self) { i in
                        ActivityRow(entry: recent[i], showProject: false)
                    }
                }
            }

            Section {
                Button("Remove Project…", role: .destructive) { confirmingRemove = true }
            } footer: {
                Text("Stops it and removes it from the list. The folder is not deleted.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            if isDirty {
                HStack {
                    Button("Discard") { reset(to: project) }
                    Spacer()
                    Button("Save Changes", action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                }
                .padding(12)
                .background(.bar)
            }
        }
        .onChange(of: project) { old, new in
            // Pick up changes made elsewhere (CLI, another window) unless the user is editing.
            if draft == old && Self.parseEnv(envText) == old.env { reset(to: new) }
        }
        .confirmationDialog("Remove \(project.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { model.remove(project) }
        } message: {
            Text("It will be stopped and removed from Container Control. The folder is not deleted.")
        }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                ProjectLogo(project: project, size: 64)
                    .overlay {
                        if logoTargeted {
                            RoundedRectangle(cornerRadius: 15).strokeBorder(Color.accentColor, lineWidth: 3)
                        }
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first else { return false }
                        model.setLogo(project.id, image: url)
                        return true
                    } isTargeted: { logoTargeted = $0 }
                    .help("Drop an image to change the logo")
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name).font(.title3.weight(.semibold)).lineLimit(2)
                    HStack {
                        Button("Change Logo…", action: chooseLogo)
                        if project.logo != nil {
                            Button("Remove") { model.removeLogo(project.id) }
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var controls: some View {
        Section {
            let status = model.status(project.id)
            let active = model.isActive(project.id)
            HStack {
                StatusLabel(status: status, busy: model.isBusy(project.id))
                    .font(.callout)
                Spacer()
                PowerToggle(project: project)
            }
            if let detail = status?.detail {
                Text(detail).font(.caption).foregroundStyle(status?.state == .crashed ? .red : .secondary)
            }
            HStack {
                Button("Restart") { model.restart(project) }
                    .disabled(!active || model.isBusy(project.id))
                if let url = model.webURL(project) {
                    Button(url.host() ?? url.absoluteString) { model.openInBrowser(project) }
                        .disabled(!active)
                }
                Button("Logs") { openWindow(id: LogsWindow.id, value: project.id) }
                Spacer()
                Menu("Open") {
                    Button("Finder") { model.revealInFinder(project) }
                    Button("Terminal") { model.openInTerminal(project) }
                    if let editor = AppModel.editorName {
                        Button(editor) { model.openInEditor(project) }
                    }
                }
                .fixedSize()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var publishSection: some View {
        Section {
            if let url = project.publicURL {
                LabeledContent("Public URL") {
                    HStack(spacing: 6) {
                        Link(url.replacingOccurrences(of: "https://", with: ""), destination: URL(string: url)!)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                }
                Button("Unpublish", role: .destructive) { model.unpublish(project) }
                    .disabled(model.isBusy(project.id))
            } else {
                Button(model.isBusy(project.id) ? "Opening tunnel…" : "Publish with Cloudflare…") { confirmingPublish = true }
                    .disabled(project.port == nil || model.isBusy(project.id))
            }
        } header: {
            Text("Publish to the Internet")
        } footer: {
            Text(project.publicURL == nil
                 ? "Creates a temporary https://….trycloudflare.com link, no account needed. It changes every time you publish and stops working when you unpublish or restart the Mac."
                 : "Anyone with this link can see it. If the project is stopped, it shows a “stopped” page. Once unpublished, the link stops existing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Publish \(project.name) to the internet?", isPresented: $confirmingPublish) {
            Button("Publish") { model.publish(project) }
        } message: {
            Text("Anyone with the link can open it, without signing in. Cloudflare Quick Tunnels have no uptime guarantee: use them for demos and testing, not for sensitive data.")
        }
    }

    private var hostnameBinding: Binding<String> {
        Binding(get: { draft.hostname ?? "" }, set: { draft.hostname = $0.isEmpty ? nil : $0 })
    }

    // MARK: Helpers

    private var runFooter: String {
        switch draft.kind {
        case .node, .custom: "Runs in the background with launchd and keeps running even if you quit the app. The port is used to know when it is ready."
        case .compose: "Uses docker compose up -d and docker compose down in the project folder."
        case .dockerfile: "Builds the image and runs a container, publishing the given port."
        }
    }

    private var permissionFooter: String {
        switch draft.agentPermission {
        case .none: "Agents do not see this project."
        case .read: "Agents can see the status and logs, but not start or stop it."
        case .control: "Claude Code, Codex and other agents can start, stop and restart it with cctl."
        case .confirm: "When an agent wants to start or stop it, you get a notification to allow or deny it. If you do not answer within 90 seconds, it is denied."
        }
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func reset(to project: Project) {
        draft = project
        envText = Self.envText(project.env)
    }

    private func save() {
        var updated = draft
        updated.name = updated.name.trimmingCharacters(in: .whitespaces)
        if updated.name.isEmpty { updated.name = project.name }
        updated.env = Self.parseEnv(envText)
        updated.hostname = updated.hostname.map(Hostnames.normalize).flatMap { $0.isEmpty || $0 == project.id ? nil : $0 }
        draft = updated
        model.save(updated)
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(fileURLWithPath: project.path)
        panel.prompt = "Use as Logo"
        if panel.runModal() == .OK, let url = panel.url { model.setLogo(project.id, image: url) }
    }

    static func envText(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0]!)" }.joined(separator: "\n")
    }

    static func parseEnv(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { env[key] = String(trimmed[trimmed.index(after: eq)...]) }
        }
        return env
    }
}

/// A form row whose value, not its label, is monospaced.
private struct CodeField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
        }
    }
}
