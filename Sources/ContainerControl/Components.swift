import AppKit
import ControlCore
import SwiftUI

// MARK: - Logo

/// Caches decoded logos, invalidated when the file's modification date changes.
@MainActor
enum LogoCache {
    private static var images: [String: (modified: Date?, image: NSImage?)] = [:]

    static func image(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let cached = images[path], cached.modified == modified { return cached.image }
        let image = modified == nil ? nil : NSImage(contentsOfFile: path)
        images[path] = (modified, image)
        return image
    }
}

struct ProjectLogo: View {
    let project: Project
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let image = LogoCache.image(project.logo) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.08)
                    .background(.quaternary.opacity(0.5))
            } else {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var initials: String {
        let words = project.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(project.name.prefix(2))
        return String(letters).uppercased()
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .cyan, .red]
        let hash = project.id.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}

// MARK: - Status

extension RunState {
    var title: String {
        switch self {
        case .running: "Running"
        case .starting: "Starting"
        case .stopped: "Stopped"
        case .crashed: "Error"
        case .external: "External"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .starting: .orange
        case .stopped: .secondary
        case .crashed: .red
        case .external: .purple
        case .unknown: .gray
        }
    }
}

struct StatusDot: View {
    let state: RunState

    var body: some View {
        Circle()
            .fill(state == .stopped ? Color.secondary.opacity(0.4) : state.color)
            .frame(width: 8, height: 8)
            .shadow(color: state == .running ? .green.opacity(0.6) : .clear, radius: 3)
    }
}

struct StatusLabel: View {
    let status: ProjectStatus?
    var busy = false

    var body: some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.mini)
                Text("Working…")
            } else {
                StatusDot(state: state)
                Text(state.title)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(status?.detail ?? "")
    }

    private var state: RunState { status?.state ?? .unknown }
}

/// The on/off switch, or a spinner while an action runs.
struct PowerToggle: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let state = model.status(project.id)?.state
        if model.isBusy(project.id) {
            ProgressView().controlSize(.small).frame(width: 38)
        } else {
            Toggle("", isOn: Binding(get: { model.isActive(project.id) }, set: { _ in model.toggle(project) }))
                .toggleStyle(.switch)
                .tint(.green)
                .labelsHidden()
                .controlSize(.small)
                .disabled(state == .external || state == .unknown || state == nil)
                .help(helpText(state))
        }
    }

    private func helpText(_ state: RunState?) -> String {
        switch state {
        case .external: "The port is taken by a process Container Control did not start"
        case .unknown, nil: "Could not read the status"
        default: model.isActive(project.id) ? "Stop" : "Start"
        }
    }
}

struct PortLink: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        if let port = project.port, let url = model.webURL(project) {
            Button(model.proxy.running ? "\(project.hostname ?? project.id).localhost" : ":\(String(port))") { model.openInBrowser(project) }
                .buttonStyle(.link)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .disabled(!model.isActive(project.id))
                .help("Open \(url.absoluteString) (port \(String(port)))")
        }
    }
}

struct KindBadge: View {
    let kind: ProjectKind

    var body: some View {
        Label(kind.title, systemImage: kind.symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

extension ProjectKind {
    var title: String {
        switch self {
        case .node: "Node"
        case .compose: "Compose"
        case .dockerfile: "Docker"
        case .custom: "Command"
        }
    }

    var symbol: String {
        switch self {
        case .node: "hexagon"
        case .compose: "square.stack.3d.up"
        case .dockerfile: "shippingbox"
        case .custom: "terminal"
        }
    }
}

extension Project {
    var shortPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Shared context menu for a project in the menu bar, cards and inspector.
struct ProjectActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let project: Project

    var body: some View {
        let active = model.isActive(project.id)
        Button(active ? "Stop" : "Start") { model.toggle(project) }
        Button("Restart") { model.restart(project) }.disabled(!active)
        Button("View Logs") {
            openWindow(id: LogsWindow.id, value: project.id)
            NSApp.activate()
        }
        Divider()
        if project.port != nil {
            Button("Open in Browser") { model.openInBrowser(project) }.disabled(!active)
        }
        Button("Show in Finder") { model.revealInFinder(project) }
        Button("Open in Terminal") { model.openInTerminal(project) }
        if let editor = AppModel.editorName {
            Button("Open in \(editor)") { model.openInEditor(project) }
        }
    }
}

/// An agent's pending request, with buttons to approve or deny it.
struct RequestBanner: View {
    @Environment(AppModel.self) private var model
    let request: ConfirmationRequest

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.describe(request))
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                if let changes = request.changes, !changes.isEmpty {
                    Text(changes.summary)
                        .font(.caption)
                        .lineLimit(3)
                        .help(changes.summary)
                }
                HStack(spacing: 3) {
                    Text("Expires in")
                    Text(timerInterval: Date()...max(Date(), request.expiresAt), countsDown: true)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Deny") { model.resolve(request.id, approve: false) }
            Button("Allow") { model.resolve(request.id, approve: true) }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .controlSize(.small)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }
}

/// Globe shown while a project is published on the internet.
struct PublicBadge: View {
    let project: Project

    var body: some View {
        if let url = project.publicURL {
            if let destination = URL(string: url) { Link(destination: destination) {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            .help("Published at \(url)") }
        }
    }
}
