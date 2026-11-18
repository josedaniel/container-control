import AppKit
import ControlCore
import SwiftUI

/// Follows a project's logs (`tail -F` or `docker … logs --follow`) and keeps the newest lines.
/// Restarts the follower when it exits, since docker stops following when containers stop.
@MainActor @Observable
final class LogStream {
    static let maxLines = 5000
    static let trimBatch = 1000

    private(set) var lines: [String] = []
    /// Lines appended since the stream started; `lines` holds the last `lines.count` of them.
    private(set) var total = 0
    /// Bumped when the view is cleared, so the text view re-renders from scratch.
    private(set) var generation = 0
    private(set) var following = false

    private let projectId: String
    private let service: ControlService
    private var process: Process?
    private var partial = ""
    private var stopped = false
    private var launches = 0

    init(projectId: String, service: ControlService) {
        self.projectId = projectId
        self.service = service
    }

    var firstIndex: Int { total - lines.count }

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    func clear() {
        lines.removeAll()
        generation += 1
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        let invocation: Invocation
        do {
            // Only the first follower replays history; later ones (after docker exits) pick up new lines.
            invocation = try service.logs(projectId, tail: launches == 0 ? 500 : 0, follow: true, actor: .app)
        } catch {
            append("[\(error.localizedDescription)]\n")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        if let cwd = invocation.cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env = invocation.environment { process.environment = env }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }

        do {
            try process.run()
            self.process = process
            launches += 1
            following = true
        } catch {
            append("[Could not read the logs: \(error.localizedDescription)]\n")
        }
    }

    private func ended() {
        process = nil
        following = false
        guard !stopped else { return }
        // Docker exits as soon as its containers stop; tail -F only exits on error. Try again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
    }

    private func append(_ chunk: String) {
        let text = partial + ANSI.strip(chunk)
        var parts = text.components(separatedBy: "\n")
        partial = parts.removeLast()
        guard !parts.isEmpty else { return }
        lines.append(contentsOf: parts)
        total += parts.count
        if lines.count > Self.maxLines + Self.trimBatch {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }
}

// MARK: - Window

struct LogsWindow: View {
    static let id = "logs"

    @Environment(AppModel.self) private var model
    let projectId: String

    @State private var stream: LogStream?
    @State private var autoscroll = true
    @State private var filter = ""

    var body: some View {
        let project = model.projects.first { $0.id == projectId }
        Group {
            if let stream {
                // Passing total/generation makes SwiftUI call updateNSView when lines arrive.
                LogTextView(stream: stream, total: stream.total, generation: stream.generation, filter: filter, autoscroll: autoscroll)
            } else {
                Color.clear
            }
        }
        .navigationTitle(project.map { "Logs · \($0.name)" } ?? "Logs")
        .navigationSubtitle(model.status(projectId)?.state.title ?? "")
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItemGroup {
                if let project {
                    PowerToggle(project: project)
                }
                Toggle(isOn: $autoscroll) {
                    Label("Follow", systemImage: "arrow.down.to.line")
                }
                .help("Scroll to new lines automatically")
                Button {
                    stream?.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear the view (does not delete the file)")
                if let project, project.kind.usesLaunchd {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([model.service.paths.logFile(for: project.id)])
                    } label: {
                        Label("Show File", systemImage: "doc.text.magnifyingglass")
                    }
                    .help("Show the log file in Finder")
                }
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .dockPresence()
        .onAppear {
            let stream = LogStream(projectId: projectId, service: model.service)
            self.stream = stream
            stream.start()
        }
        .onDisappear { stream?.stop() }
    }
}

/// NSTextView-backed log view: selectable, fast, and appends incrementally.
struct LogTextView: NSViewRepresentable {
    let stream: LogStream
    let total: Int
    let generation: Int
    let filter: String
    let autoscroll: Bool

    final class Coordinator {
        var renderedTotal = 0
        var generation = -1
        var filter = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.font = Self.font
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        let c = context.coordinator
        let lines = stream.lines
        let first = stream.firstIndex

        let needsFull = c.generation != stream.generation || c.filter != filter || c.renderedTotal < first
        let newLines: ArraySlice<String>
        if needsFull {
            storage.setAttributedString(NSAttributedString())
            newLines = lines[...]
        } else {
            newLines = lines[(c.renderedTotal - first)...]
        }
        c.generation = stream.generation
        c.filter = filter
        c.renderedTotal = stream.total
        guard !newLines.isEmpty || needsFull else { return }

        let output = NSMutableAttributedString()
        for line in newLines where filter.isEmpty || line.localizedCaseInsensitiveContains(filter) {
            output.append(NSAttributedString(string: line + "\n", attributes: Self.attributes(for: line)))
        }
        storage.append(output)
        if autoscroll { text.scrollToEndOfDocument(nil) }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    static func attributes(for line: String) -> [NSAttributedString.Key: Any] {
        let lower = line.lowercased()
        let color: NSColor
        if lower.hasPrefix("===") {
            color = .secondaryLabelColor
        } else if lower.contains("error") || lower.contains("exception") || lower.contains("fatal") || lower.contains(" err!") {
            color = .systemRed
        } else if lower.contains("warn") {
            color = .systemOrange
        } else {
            color = .labelColor
        }
        return [.font: font, .foregroundColor: color]
    }
}
