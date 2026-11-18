import AppKit
import SwiftUI

/// Development aid: `CCTL_SNAPSHOT=<dir> ContainerControl` renders the main views to PNG files
/// in offscreen windows and quits, so the UI can be reviewed without screen-recording access.
@MainActor
enum Snapshot {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["CCTL_SNAPSHOT"].map { URL(fileURLWithPath: $0) }
    }

    static func run(model: AppModel, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task {
            try? await Task.sleep(for: .seconds(3))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                model.selection = nil
                await render(MenuBarView().environment(model), size: CGSize(width: 340, height: 300), appearance: appearance,
                             to: dir.appendingPathComponent("menubar-\(suffix).png"))
                await render(NavigationStack { MainWindow() }.environment(model), size: CGSize(width: 980, height: 560), appearance: appearance,
                             to: dir.appendingPathComponent("window-\(suffix).png"))
            }
            model.selection = model.projects.first?.id
            await render(NavigationStack { MainWindow() }.environment(model), size: CGSize(width: 1180, height: 900), appearance: .aqua,
                         to: dir.appendingPathComponent("inspector-light.png"))
            await render(ActivityWindow().environment(model), size: CGSize(width: 560, height: 360), appearance: .aqua,
                         to: dir.appendingPathComponent("activity-light.png"))
            if let id = model.projects.first?.id {
                await render(LogsWindow(projectId: id).environment(model), size: CGSize(width: 760, height: 360), appearance: .darkAqua,
                             to: dir.appendingPathComponent("logs-dark.png"), settle: 2.5)
            }
            await render(SettingsView().environment(model), size: CGSize(width: 460, height: 360), appearance: .aqua,
                         to: dir.appendingPathComponent("settings-light.png"))
            NSApp.terminate(nil)
        }
    }

    /// Waits with `Task.sleep` rather than spinning the run loop, so main-actor work
    /// (status refreshes, log lines) keeps flowing while the view settles.
    private static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL, settle: TimeInterval = 0.8) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderBack(nil)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        try? await Task.sleep(for: .seconds(settle))
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        host.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }
}
