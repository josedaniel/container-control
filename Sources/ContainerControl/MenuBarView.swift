import ControlCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Container Control").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.projects.isEmpty { RunningCount(running: model.runningCount, total: model.projects.count) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if !model.requests.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.requests) { RequestBanner(request: $0) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            if model.projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox").font(.title).foregroundStyle(.secondary)
                    Text("No projects yet").font(.callout)
                    Button("Add Project…") { showWindow() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.projects) { project in
                            MenuBarRow(project: project) { showWindow(selecting: project.id) }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.horizontal, 14).padding(.top, 6)

            HStack(spacing: 2) {
                MenuButton(title: "Open Window", symbol: "macwindow") { showWindow() }
                Spacer()
                if model.runningCount > 0 {
                    MenuButton(title: "Stop All", symbol: "stop.circle", tint: .red) { model.stopAll() }
                        .help("Stop the \(model.runningCount) running projects")
                }
                MenuButton(symbol: "clock.arrow.circlepath") {
                    openWindow(id: ActivityWindow.id)
                    NSApp.activate()
                }
                .help("Activity")
                MenuButton(symbol: "gearshape") {
                    openSettings()
                    NSApp.activate()
                }
                .help("Settings")
                MenuButton(symbol: "power") { NSApp.terminate(nil) }
                    .help("Quit Container Control. Projects keep running.")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 340)
    }

    private func showWindow(selecting id: String? = nil) {
        if let id { model.selection = id }
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }
}

/// "2 of 3 running", green while something runs.
private struct RunningCount: View {
    let running: Int
    let total: Int

    var body: some View {
        Text("\(running) of \(total) running")
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(running > 0 ? Color.green : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((running > 0 ? Color.green : Color.primary).opacity(0.12), in: Capsule())
    }
}

/// Borderless footer button that highlights on hover, like a menu item.
private struct MenuButton: View {
    var title: String?
    let symbol: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 13))
                if let title { Text(title).font(.system(size: 12)) }
            }
            .foregroundStyle(tint == .primary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            .padding(.horizontal, title == nil ? 6 : 8)
            .frame(height: 26)
            .background(hovering ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MenuBarRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ProjectLogo(project: project, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusLabel(status: model.status(project.id), busy: model.isBusy(project.id))
                    if model.isActive(project.id) {
                        PortLink(project: project)
                        PublicBadge(project: project)
                    }
                }
            }
            Spacer(minLength: 8)
            PowerToggle(project: project)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .help("Double-click to edit")
        .contextMenu {
            ProjectActions(project: project)
            Divider()
            Button("Edit…", action: onOpen)
        }
    }
}
