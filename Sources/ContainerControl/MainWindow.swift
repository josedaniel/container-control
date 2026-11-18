import AppKit
import ControlCore
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    static let id = "main"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var dropTargeted = false

    private var filtered: [Project] {
        guard !search.isEmpty else { return model.projects }
        return model.projects.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 16, alignment: .top)], spacing: 16) {
                ForEach(filtered) { project in
                    ProjectCard(project: project, selected: model.selection == project.id)
                        .onTapGesture { model.selection = model.selection == project.id ? nil : project.id }
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.requests.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.requests) { RequestBanner(request: $0) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
        }
        .overlay {
            if model.projects.isEmpty { EmptyState(add: chooseFolders) }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.06))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath }
            guard !folders.isEmpty else { return false }
            model.add(folders: folders)
            return true
        } isTargeted: { dropTargeted = $0 }
        .inspector(isPresented: Binding(get: { model.selection != nil }, set: { if !$0 { model.selection = nil } })) {
            if let project = model.selectedProject {
                ProjectInspector(project: project)
                    .id(project.id)
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .navigationTitle("Container Control")
        .navigationSubtitle(model.projects.isEmpty ? "" : "\(model.runningCount) of \(model.projects.count) running")
        .toolbar {
            ToolbarItemGroup {
                Button(action: chooseFolders) {
                    Label("Add Project", systemImage: "plus")
                }
                .help("Add one or more project folders")
                Menu {
                    Button("Stop All") { model.stopAll() }.disabled(model.runningCount == 0)
                    Button("Refresh Status") { model.reload() }
                    Divider()
                    Button("Activity") { openWindow(id: ActivityWindow.id) }
                    SettingsLink { Text("Settings…") }
                    Divider()
                    Button("Install cctl Command") { model.installCLI() }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Container Control", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .frame(minWidth: 560, minHeight: 380)
        .dockPresence()
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose your project folders"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
        if panel.runModal() == .OK { model.add(folders: panel.urls) }
    }
}

private struct EmptyState: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Add your first project").font(.title3.weight(.semibold))
            Text("Drop a Node or Docker project folder here,\nor choose it with the button.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose Folders…", action: add)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(40)
    }
}

struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let status = model.status(project.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ProjectLogo(project: project, size: 46)
                Spacer()
                PowerToggle(project: project)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(project.shortPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                StatusLabel(status: status, busy: model.isBusy(project.id))
                Spacer()
                PortLink(project: project)
                PublicBadge(project: project)
                KindBadge(kind: project.kind)
            }
            if let detail = status?.detail, !model.isBusy(project.id) {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(status?.state == .crashed ? .red : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(hovering ? 0.12 : 0.06), radius: hovering ? 6 : 3, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
        }
        .overlay(alignment: .leading) {
            if status?.isActive == true {
                Capsule().fill(Color.green).frame(width: 3).padding(.vertical, 14)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            ProjectActions(project: project)
            Divider()
            Button("Edit…") { model.selection = project.id }
        }
    }
}
