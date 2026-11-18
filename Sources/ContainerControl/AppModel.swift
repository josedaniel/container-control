import AppKit
import ControlCore
import SwiftUI
import UserNotifications

/// State shared by the menu bar and the main window.
///
/// The source of truth is on disk (`projects.json`, launchd, docker), because the CLI and
/// AI agents change it too. We re-read it when the config folder changes and poll statuses.
@MainActor @Observable
final class AppModel {
    let service = ControlService()

    private(set) var projects: [Project] = []
    private(set) var statuses: [String: ProjectStatus] = [:]
    private(set) var busy: Set<String> = []
    private(set) var activity: [ActivityEntry] = []
    /// Agent actions waiting for the person to approve them.
    private(set) var requests: [ConfirmationRequest] = []
    /// Whether `http://<id>.localhost` domains are set up and serving.
    private(set) var proxy = ProxyAgent.State(installed: false, running: false)
    var selection: String?
    var errorMessage: String?

    private var timer: Timer?
    private var watcher: DirectoryWatcher?
    private var requestsWatcher: DirectoryWatcher?
    private var notifiedRequests: Set<String> = []
    private let notifications = NotificationHandler()
    private var refreshing = false
    private var refreshQueued = false
    private var activityModified: Date?
    /// Agent actions after this date have not been notified yet.
    private var notifiedUntil = Date()
    private var openWindows = 0

    static let pollInterval: TimeInterval = 4

    init() {
        reload()
        try? service.paths.ensure()
        watcher = DirectoryWatcher(url: service.paths.base) { [weak self] in self?.reload() }
        requestsWatcher = DirectoryWatcher(url: service.paths.requestsDir) { [weak self] in self?.loadRequests() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatuses()
                self?.loadActivity()
                self?.loadRequests()
                self?.refreshProxy()
            }
        }
        if Self.canNotify {
            notifications.model = self
            UNUserNotificationCenter.current().delegate = notifications
            UNUserNotificationCenter.current().setNotificationCategories([NotificationHandler.confirmationCategory])
            // Confirmation requests always notify, so ask even if agent-action notifications are off.
            requestNotificationPermission()
        }
        loadRequests()
    }

    /// UNUserNotificationCenter needs an app bundle; `swift run` binaries have none.
    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    // MARK: Queries

    var runningCount: Int { projects.filter { isActive($0.id) }.count }

    func status(_ id: String) -> ProjectStatus? { statuses[id] }

    func isActive(_ id: String) -> Bool { statuses[id]?.isActive ?? false }

    func isBusy(_ id: String) -> Bool { busy.contains(id) }

    var selectedProject: Project? { projects.first { $0.id == selection } }

    // MARK: Loading

    func reload() {
        service.syncPublished()
        do {
            projects = try service.projects(actor: .app)
        } catch {
            errorMessage = error.localizedDescription
        }
        if let selection, !projects.contains(where: { $0.id == selection }) { self.selection = nil }
        refreshStatuses()
        loadActivity()
        refreshProxy()
    }

    // MARK: Domains

    func refreshProxy() {
        let agent = service.proxy
        Task {
            let state = await Task.detached { agent.state() }.value
            if state != proxy { proxy = state }
        }
    }

    /// Where a project opens: its .localhost domain while the proxy runs, else localhost:port.
    func webURL(_ project: Project) -> URL? {
        proxy.running ? service.webURL(project) : service.directURL(project)
    }

    func setDomains(_ enabled: Bool) {
        let service = service
        let executable = AgentSetup.cctlPath
        Task {
            let error = await Task.detached { () -> String? in
                do {
                    try service.setDomains(enabled, actor: .app, executable: executable)
                    usleep(600_000)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let error { errorMessage = error }
            refreshProxy()
        }
    }

    // MARK: Activity

    /// Re-reads the activity log when it changed, and notifies about new agent actions.
    func loadActivity() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: service.paths.activityFile.path))?[.modificationDate] as? Date
        guard modified != activityModified else { return }
        activityModified = modified
        activity = service.activity(limit: 500)
        notifyAgentActions()
    }

    func activity(for id: String, limit: Int) -> [ActivityEntry] {
        Array(activity.lazy.filter { $0.projectId == id }.suffix(limit).reversed())
    }

    func describe(_ entry: ActivityEntry, includeProject: Bool = true) -> String {
        let name = projects.first { $0.id == entry.projectId }?.name ?? entry.projectId
        let target = includeProject ? " \(name)" : ""
        let verb: String
        switch entry.action {
        case "start": verb = entry.ok ? "started" : "tried to start"
        case "stop": verb = entry.ok ? "stopped" : "tried to stop"
        case "restart": verb = entry.ok ? "restarted" : "tried to restart"
        case "add": verb = "added"
        case "remove": verb = "removed"
        case "domains:on", "domains:off":
            return "\(entry.actor) \(entry.action == "domains:on" ? "turned on" : "turned off") the .localhost domains"
        case "port": return "Container Control moved\(includeProject ? " \(name)" : "") to another port"
        case "edit": verb = entry.ok ? "changed the configuration of" : "tried to change"
        case "publish": return "\(entry.actor) published\(target) to the internet"
        case "unpublish": verb = "unpublished"
        case let action where action.hasPrefix("permission:"):
            let level = AgentPermission(rawValue: String(action.dropFirst("permission:".count)))?.title ?? action
            return "\(entry.actor) changed the agent permission\(includeProject ? " of \(name)" : "") to “\(level)”"
        default: verb = entry.action
        }
        return "\(entry.actor) \(verb)\(target)"
    }

    // MARK: Confirmations

    func loadRequests() {
        let current = service.pendingRequests()
        guard current != requests else { return }
        requests = current
        for request in current where !notifiedRequests.contains(request.id) {
            notifiedRequests.insert(request.id)
            notifyConfirmation(request)
        }
        // Withdraw notifications for requests that were answered elsewhere or expired.
        if Self.canNotify {
            let open = Set(current.map(\.id))
            let closed = notifiedRequests.subtracting(open)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: closed.map { "request-\($0)" })
        }
    }

    func describe(_ request: ConfirmationRequest) -> String {
        let name = projects.first { $0.id == request.projectId }?.name ?? request.projectId
        switch Action(rawValue: request.action) {
        case .edit:
            return "\(request.actor) wants to change \(name)"
        case .permission:
            let level = request.value.flatMap(AgentPermission.init(rawValue:))?.title ?? request.value ?? "?"
            return "\(request.actor) wants to change the agent permission of \(name) to “\(level)”"
        case .domains:
            return "\(request.actor) wants to \(request.value == "on" ? "turn on" : "turn off") the .localhost domains"
        case .publish:
            return "\(request.actor) wants to publish \(name) to the internet"
        default:
            let verb = Action(rawValue: request.action)?.verb ?? request.action
            return "\(request.actor) wants to \(verb) \(name)"
        }
    }

    func resolve(_ requestId: String, approve: Bool) {
        guard let request = requests.first(where: { $0.id == requestId }) else { return }
        requests.removeAll { $0.id == requestId }
        run(request.projectId) { try $0.resolve(requestId, approve: approve) }
    }

    private func notifyConfirmation(_ request: ConfirmationRequest) {
        guard Self.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = describe(request)
        content.body = "Allow or deny it before \(request.expiresAt.formatted(date: .omitted, time: .shortened))."
        content.sound = .default
        content.categoryIdentifier = NotificationHandler.confirmationCategory.identifier
        content.userInfo = ["requestId": request.id]
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "request-\(request.id)", content: content, trigger: nil))
    }

    func requestNotificationPermission() {
        guard Self.canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyAgentActions() {
        let fresh = activity.filter { $0.isAgent && $0.date > notifiedUntil }
        guard let last = fresh.last else { return }
        notifiedUntil = last.date
        guard Bundle.main.bundleIdentifier != nil,
              UserDefaults.standard.object(forKey: Preferences.notifyAgentActions) as? Bool ?? true else { return }
        for entry in fresh.suffix(3) {
            let content = UNMutableNotificationContent()
            content.title = describe(entry)
            if let message = entry.message { content.body = message }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: Dock

    /// Shows the Dock icon while any window is open; the app is menu-bar-only otherwise.
    func windowAppeared() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
    }

    func windowDisappeared() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }

    func refreshStatuses() {
        guard !refreshing else {
            refreshQueued = true
            return
        }
        refreshing = true
        let projects = projects
        let service = service
        Task {
            let result = await Task.detached { service.statuses(projects) }.value
            statuses = result
            refreshing = false
            if refreshQueued {
                refreshQueued = false
                refreshStatuses()
            }
        }
    }

    // MARK: Actions

    func toggle(_ project: Project) {
        isActive(project.id) ? stop(project) : start(project)
    }

    func start(_ project: Project) {
        run(project.id) { try $0.start(project.id, actor: .app) }
    }

    func stop(_ project: Project) {
        run(project.id) { try $0.stop(project.id, actor: .app) }
    }

    func restart(_ project: Project) {
        run(project.id) { try $0.restart(project.id, actor: .app) }
    }

    func stopAll() {
        for project in projects where isActive(project.id) { stop(project) }
    }

    func add(folders: [URL]) {
        var added: String?
        for folder in folders {
            do {
                added = try service.add(folder: folder.path, actor: .app).id
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        reload()
        if let added { selection = added }
    }

    func save(_ project: Project) {
        perform { try $0.edit(project.id, actor: .app) { $0 = project } }
    }

    func setLogo(_ id: String, image: URL) {
        perform { try $0.setLogo(id, image: image.path, actor: .app) }
    }

    func removeLogo(_ id: String) {
        perform { try $0.edit(id, actor: .app) { $0.logo = nil } }
    }

    func publish(_ project: Project) {
        run(project.id) { try $0.publish(project.id, actor: .app) }
    }

    func unpublish(_ project: Project) {
        run(project.id) { try $0.unpublish(project.id, actor: .app) }
    }

    func remove(_ project: Project) {
        if selection == project.id { selection = nil }
        run(project.id) { try $0.remove(project.id, actor: .app) }
    }

    /// Runs a quick, synchronous config change on the main thread.
    private func perform(_ body: (ControlService) throws -> Any) {
        do {
            _ = try body(service)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    /// Runs a slow action (docker, launchctl) in the background, marking the project busy.
    private func run(_ id: String, _ body: @escaping @Sendable (ControlService) throws -> Any) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        let service = service
        Task {
            let error = await Task.detached { () -> String? in
                do {
                    _ = try body(service)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            busy.remove(id)
            if let error { errorMessage = error }
            reload()
        }
    }

    // MARK: Opening things

    func openInBrowser(_ project: Project) {
        guard let url = webURL(project) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    func openInTerminal(_ project: Project) {
        open(project, bundleIDs: ["com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.Terminal"])
    }

    func openInEditor(_ project: Project) {
        open(project, bundleIDs: ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed", "com.apple.dt.Xcode"])
    }

    static let editorName: String? = firstApp(["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed"])
        .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }

    private func open(_ project: Project, bundleIDs: [String]) {
        guard let app = Self.firstApp(bundleIDs) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: project.path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func firstApp(_ bundleIDs: [String]) -> URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    // MARK: CLI install

    /// Links the `cctl` bundled in the app into `~/.local/bin`.
    func installCLI() {
        guard let source = Bundle.main.url(forAuxiliaryExecutable: "cctl") else {
            errorMessage = "This copy of the app does not include cctl. Build it with scripts/build-app.sh."
            return
        }
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let target = bin.appendingPathComponent("cctl")
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
            errorMessage = "cctl installed at \(target.path)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Calls back (debounced, on the main actor) when a directory's entries change.
/// Atomic writes of `projects.json` replace the file, which counts as a change.
final class DirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

extension AgentPermission {
    var title: String {
        switch self {
        case .none: "No access"
        case .read: "View only"
        case .control: "Start and stop"
        case .confirm: "Ask first"
        }
    }
}

private struct DockPresence: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onAppear { model.windowAppeared() }
            .onDisappear { model.windowDisappeared() }
    }
}

extension View {
    /// Keeps the Dock icon visible while this window is open.
    func dockPresence() -> some View { modifier(DockPresence()) }
}

/// Receives notification actions (Permitir / Rechazar) and shows banners while the app is active.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let approve = "approve"
    static let deny = "deny"
    static var confirmationCategory: UNNotificationCategory { UNNotificationCategory(
        identifier: "confirmation",
        actions: [
            UNNotificationAction(identifier: approve, title: "Allow"),
            UNNotificationAction(identifier: deny, title: "Deny", options: [.destructive]),
        ],
        intentIdentifiers: []
    ) }

    @MainActor weak var model: AppModel?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let requestId = response.notification.request.content.userInfo["requestId"] as? String else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.approve: model?.resolve(requestId, approve: true)
            case Self.deny: model?.resolve(requestId, approve: false)
            default: NSApp.activate() // clicked the notification: the banner in the menu or window decides
            }
        }
    }
}
