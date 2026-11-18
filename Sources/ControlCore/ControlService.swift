import Foundation

/// Who is asking for an action: you in a terminal or the app, or an AI agent.
public struct Actor: Codable, Sendable, Equatable {
    public var name: String
    public var isAgent: Bool

    public init(name: String, isAgent: Bool) {
        self.name = name
        self.isAgent = isAgent
    }

    public static let app = Actor(name: "App", isAgent: false)

    /// Identifies the caller from its environment. `CCTL_ACTOR` names an agent explicitly.
    public static func detect(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Actor {
        if let name = env["CCTL_ACTOR"], !name.isEmpty { return Actor(name: name, isAgent: true) }
        if env["CLAUDECODE"] == "1" { return Actor(name: "Claude Code", isAgent: true) }
        if env.keys.contains(where: { $0.hasPrefix("CODEX_") }) { return Actor(name: "Codex", isAgent: true) }
        if env["GEMINI_CLI"] == "1" { return Actor(name: "Gemini CLI", isAgent: true) }
        return Actor(name: "Terminal", isAgent: false)
    }
}

public struct ActivityEntry: Codable, Sendable {
    public var date: Date
    public var projectId: String
    public var action: String
    public var actor: String
    public var ok: Bool
    public var message: String?
    /// Whether an AI agent did it. Missing in entries written before this field existed.
    public var agent: Bool?

    public var isAgent: Bool { agent ?? false }
}

public enum Action: String, Sendable {
    case read, start, stop, restart, edit
    /// Decisions that are always the person's: agents may ask, and wait for approval.
    case remove, publish, unpublish, permission, domains

    var needsControl: Bool { self != .read }

    /// Whether an agent always needs the person's approval, whatever the project permission.
    public var requiresPerson: Bool {
        switch self {
        case .remove, .publish, .unpublish, .permission, .domains: true
        default: false
        }
    }
}

/// Single entry point for the app, the CLI and the MCP server.
public struct ControlService: Sendable {
    public let paths: Paths
    public let store: ProjectStore
    /// How long an agent waits for the person to approve an action.
    public var confirmationTimeout: TimeInterval
    /// Whether the app is open to show confirmation requests.
    public var isAppRunning: @Sendable () -> Bool

    public init(paths: Paths = Paths()) {
        self.paths = paths
        self.store = ProjectStore(paths: paths)
        self.confirmationTimeout = ProcessInfo.processInfo.environment["CCTL_CONFIRM_TIMEOUT"].flatMap(TimeInterval.init) ?? 90
        self.isAppRunning = {
            (try? Shell.run("/usr/bin/pgrep", ["-x", "ContainerControl"], timeout: 5))?.ok ?? false
        }
    }

    func runner(for kind: ProjectKind) -> Runner {
        switch kind {
        case .node, .custom: LaunchdRunner(paths: paths)
        case .compose: ComposeRunner()
        case .dockerfile: DockerfileRunner()
        }
    }

    // MARK: Queries

    public func projects(actor: Actor) throws -> [Project] {
        try store.all().filter { !actor.isAgent || $0.agentPermission != .none }
    }

    public func project(_ id: String, actor: Actor) throws -> Project {
        let project = try store.get(id)
        try authorize(.read, project, actor)
        return project
    }

    public func status(_ project: Project) -> ProjectStatus {
        runner(for: project.kind).status(project)
    }

    /// Statuses for many projects at once, fetched in parallel (each one shells out).
    public func statuses(_ projects: [Project]) -> [String: ProjectStatus] {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var items: [String: ProjectStatus] = [:]
        }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: projects.count) { i in
            let status = status(projects[i])
            box.lock.withLock { box.items[status.id] = status }
        }
        return box.items
    }

    public func status(_ id: String, actor: Actor) throws -> ProjectStatus {
        status(try project(id, actor: actor))
    }

    public func logs(_ id: String, tail: Int = 200, follow: Bool = false, actor: Actor) throws -> Invocation {
        let project = try project(id, actor: actor)
        return runner(for: project.kind).logs(project, tail: tail, follow: follow)
    }

    public func logText(_ id: String, tail: Int = 200, actor: Actor) throws -> String {
        let inv = try logs(id, tail: tail, actor: actor)
        let result = try Shell.run(inv.executable, inv.arguments, cwd: inv.cwd, environment: inv.environment, timeout: 15)
        return ANSI.strip(result.stdout + result.stderr)
    }

    // MARK: Actions

    @discardableResult
    public func start(_ id: String, actor: Actor) throws -> ProjectStatus {
        try execute(.start, id, actor)
    }

    @discardableResult
    public func stop(_ id: String, actor: Actor) throws -> ProjectStatus {
        try execute(.stop, id, actor)
    }

    @discardableResult
    public func restart(_ id: String, actor: Actor) throws -> ProjectStatus {
        try execute(.restart, id, actor)
    }

    /// Runs a control action. `confirmed` is only set by the app after the person approves.
    func execute(_ action: Action, _ id: String, _ actor: Actor, confirmed: Bool = false) throws -> ProjectStatus {
        try perform(action, id, actor, confirmed: confirmed) { project, runner in
            switch action {
            case .start:
                if runner.status(project).isActive { return project }
                return try startOnFreePort(project, runner, actor)
            case .stop:
                try runner.stop(project)
                return project
            case .restart:
                try runner.stop(project)
                return try startOnFreePort(project, runner, actor)
            default:
                return project
            }
        }
    }

    // MARK: Ports

    /// Starts a project, first moving it to a free port if its own is taken and it can be moved.
    private func startOnFreePort(_ project: Project, _ runner: Runner, _ actor: Actor) throws -> Project {
        let (project, previous) = try freePortIfTaken(project, actor)
        do {
            try runner.start(project)
        } catch {
            throw explainTakenPort(error, project)
        }
        waitUntilSettled(project, runner)

        // An app that ignores PORT keeps trying the old, taken port: put things back and say why.
        if let previous, PortControl.of(project) == .environment, runner.status(project).state != .running {
            try? runner.stop(project)
            try store.update(project.id) { $0.port = previous }
            throw ControlError.commandFailed(
                "\(project.name) is not listening on the port it was given (\(project.port ?? 0)), so it does not read the PORT variable. " +
                "Port \(previous) is still taken by \(holder(of: previous, excluding: project.id)). " +
                "Make its command use $PORT or free that port.")
        }
        return project
    }

    /// Returns the project, moved to a free port when its port is taken by something else.
    private func freePortIfTaken(_ project: Project, _ actor: Actor) throws -> (Project, previous: Int?) {
        guard let port = project.port, !Ports.listeners(port).isEmpty else { return (project, nil) }
        let holder = holder(of: port, excluding: project.id)
        let control = PortControl.of(project)
        if case .fixed(let reason) = control {
            throw ControlError.commandFailed(
                "Port \(port) is taken by \(holder). \(project.name) cannot be moved to another one because \(reason). " +
                "Stop whatever is using it or change the project's port.")
        }
        let claimed = Set(try store.all().filter { $0.id != project.id }.compactMap(\.port))
        guard let free = PortControl.freePort(excluding: claimed) else {
            throw ControlError.commandFailed("Port \(port) is taken and there is no free one between \(PortControl.range.lowerBound) and \(PortControl.range.upperBound).")
        }
        let moved = try store.update(project.id) { $0.port = free }
        log(project.id, "port", actor, ok: true, message: "Port \(port) was taken by \(holder). It now uses \(free).")
        return (moved, port)
    }

    /// Who listens on a port: a registered project by name, or the process name.
    func holder(of port: Int, excluding id: String) -> String {
        if let other = try? store.all().first(where: { $0.id != id && $0.port == port }), status(other).isActive {
            return "“\(other.name)”"
        }
        if let result = try? Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fc"], timeout: 5),
           let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("c") }) {
            return "another process (\(line.dropFirst()))"
        }
        return "another process"
    }

    /// Adds who holds the port to Docker's "port is already allocated" errors, which are common
    /// when two compose projects publish the same database or cache port.
    private func explainTakenPort(_ error: Error, _ project: Project) -> Error {
        let message = error.localizedDescription
        guard message.contains("already allocated") || message.contains("address already in use"),
              let port = Detector.firstInt(in: message, pattern: #"(?:0\.0\.0\.0|\[::\]|127\.0\.0\.1):(\d+)"#) else { return error }
        return ControlError.commandFailed("Port \(port) is already used by \(holder(of: port, excluding: project.id)). \(message)")
    }

    /// Adds a folder, auto-detecting its kind. `configure` adjusts the draft before saving and
    /// `logo` is copied into our logos folder.
    ///
    /// Agents may register projects (they usually work inside one), but what they register always
    /// gets the default agent permission; only the person can change it afterwards.
    @discardableResult
    public func add(folder: String, actor: Actor, logo: String? = nil, configure: (inout Project) throws -> Void = { _ in }) throws -> Project {
        var draft = try Detector.detect(folder: folder)
        try configure(&draft)
        if actor.isAgent { draft.agentPermission = .control }
        draft.publicURL = nil
        if let hostname = draft.hostname {
            draft.hostname = Hostnames.normalize(hostname)
            try Hostnames.validate(draft.hostname!, for: draft.id, among: try store.all())
        }
        if let logo { try checkImage(logo) }
        var project = try store.add(draft)
        if let logo {
            project = try store.update(project.id) { try copyLogo(logo, into: &$0) }
        }
        log(project.id, "add", actor, ok: true)
        return project
    }

    @discardableResult
    public func edit(_ id: String, actor: Actor, change: (inout Project) throws -> Void) throws -> Project {
        let before = try store.get(id)
        if actor.isAgent {
            throw ControlError.permissionDenied("Agents change projects with update_project (cctl set), not with edit.")
        }
        let all = try store.all()
        let project = try store.update(id) { project in
            try change(&project)
            // Publishing has its own path; a stale draft from the app must not undo it.
            project.publicURL = before.publicURL
            if let hostname = project.hostname {
                project.hostname = Hostnames.normalize(hostname)
                if project.hostname == project.id || project.hostname?.isEmpty == true { project.hostname = nil }
                if let name = project.hostname { try Hostnames.validate(name, for: id, among: all) }
            }
        }
        if project.agentPermission != before.agentPermission {
            log(id, "permission:\(project.agentPermission.rawValue)", actor, ok: true)
        }
        return project
    }

    /// Partial update, used by agents (MCP `update_project`) and `cctl set`.
    ///
    /// Agents may change a project's configuration where they may control it: directly with the
    /// `control` permission, after the person approves with `confirm`. They can never change the
    /// agent permission, publish it, or move its folder; `ProjectChanges` has no such fields.
    @discardableResult
    public func update(_ id: String, _ changes: ProjectChanges, actor: Actor, confirmed: Bool = false) throws -> Project {
        let project = try store.get(id)
        guard !changes.isEmpty else { return project }
        if try authorize(.edit, project, actor) == .needsConfirmation && !confirmed {
            try validate(changes, for: project)
            _ = try awaitConfirmation(.edit, project, actor, changes: changes)
            return try store.get(id)
        }
        do {
            try validate(changes, for: project)
            let updated = try store.update(id) { project in
                changes.apply(to: &project)
                if project.hostname == project.id { project.hostname = nil }
                if let logo = changes.logo { try copyLogo(logo, into: &project) }
            }
            log(id, "edit", actor, ok: true, message: changes.summary + (confirmed ? " · approved by the person" : ""))
            return updated
        } catch {
            log(id, "edit", actor, ok: false, message: error.localizedDescription)
            throw error
        }
    }

    func validate(_ changes: ProjectChanges, for project: Project) throws {
        if let port = changes.port, port != 0, !(1...65535).contains(port) {
            throw ControlError.invalid("The port must be between 1 and 65535.")
        }
        if let hostname = changes.hostname, !hostname.isEmpty {
            let name = Hostnames.normalize(hostname)
            if name != project.id { try Hostnames.validate(name, for: project.id, among: try store.all()) }
        }
        if let logo = changes.logo { try checkImage(logo) }
        if let kind = changes.kind, kind.usesLaunchd, (changes.startCommand ?? project.startCommand ?? "").isEmpty {
            throw ControlError.invalid("A \(kind.rawValue) project needs a start command.")
        }
    }

    /// Stops and unregisters a project (its folder is untouched). Agents need approval.
    public func remove(_ id: String, actor: Actor, confirmed: Bool = false) throws {
        let project = try store.get(id)
        if try authorize(.remove, project, actor) == .needsConfirmation && !confirmed {
            _ = try awaitConfirmation(.remove, project, actor)
            return
        }
        let runner = runner(for: project.kind)
        let state = runner.status(project).state
        // Crashed jobs and exited containers are still registered, so clean them up too.
        if state == .running || state == .starting || state == .crashed { try runner.stop(project) }
        try? FileManager.default.removeItem(at: LaunchdRunner(paths: paths).plistURL(id))
        tunnels.stop(id)
        try store.remove(id)
        log(id, "remove", actor, ok: true, message: confirmed ? "Approved by the person" : nil)
    }

    /// Changes what agents may do with a project. An agent may ask (for itself or another), and
    /// the person decides.
    @discardableResult
    public func setAgentPermission(_ id: String, _ permission: AgentPermission, actor: Actor, confirmed: Bool = false) throws -> Project {
        let project = try store.get(id)
        if try authorize(.permission, project, actor) == .needsConfirmation && !confirmed {
            _ = try awaitConfirmation(.permission, project, actor, value: permission.rawValue)
            return try store.get(id)
        }
        guard permission != project.agentPermission else { return project }
        let updated = try store.update(id) { $0.agentPermission = permission }
        log(id, "permission:\(permission.rawValue)", actor, ok: true, message: confirmed ? "Approved by the person" : nil)
        return updated
    }

    /// Turns the .localhost domains proxy on or off. Agents need approval.
    public func setDomains(_ enabled: Bool, actor: Actor, confirmed: Bool = false, executable: String? = nil) throws {
        if actor.isAgent && !confirmed {
            let placeholder = Project(id: Self.systemId, name: "Container Control", path: paths.base.path, kind: .custom)
            _ = try awaitConfirmation(.domains, placeholder, actor, value: enabled ? "on" : "off")
            return
        }
        if enabled {
            try proxy.install(executable: executable ?? ProxyAgent.defaultExecutable)
        } else {
            try proxy.uninstall()
        }
        log(Self.systemId, "domains:\(enabled ? "on" : "off")", actor, ok: true, message: confirmed ? "Approved by the person" : nil)
    }

    /// Project id used in activity and requests for app-wide settings.
    public static let systemId = "*"

    /// Copies an image into our logos folder and points the project at it.
    @discardableResult
    public func setLogo(_ id: String, image: String, actor: Actor) throws -> Project {
        try checkImage(image)
        return try edit(id, actor: actor) { try copyLogo(image, into: &$0) }
    }

    private func checkImage(_ image: String) throws {
        let path = (image as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw ControlError.invalid("Image not found: \(path)")
        }
    }

    private func copyLogo(_ image: String, into project: inout Project) throws {
        let source = URL(fileURLWithPath: (image as NSString).expandingTildeInPath)
        try paths.ensure()
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let target = paths.logosDir.appendingPathComponent("\(project.id).\(ext)")
        if let old = project.logo, old.hasPrefix(paths.logosDir.path) { try? FileManager.default.removeItem(atPath: old) }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        project.logo = target.path
    }

    // MARK: Activity

    public func activity(limit: Int = 50, projectId: String? = nil) -> [ActivityEntry] {
        guard let text = try? String(contentsOf: paths.activityFile, encoding: .utf8) else { return [] }
        let entries = text.split(whereSeparator: \.isNewline).compactMap {
            try? ProjectStore.decoder.decode(ActivityEntry.self, from: Data($0.utf8))
        }
        return Array(entries.filter { projectId == nil || $0.projectId == projectId }.suffix(limit))
    }

    // MARK: Internals

    private func perform(_ action: Action, _ id: String, _ actor: Actor, confirmed: Bool = false, _ body: (Project, Runner) throws -> Project) throws -> ProjectStatus {
        let project = try store.get(id)
        if try authorize(action, project, actor) == .needsConfirmation && !confirmed {
            return try awaitConfirmation(action, project, actor)
        }
        do {
            let runner = runner(for: project.kind)
            let result = try body(project, runner)
            log(id, action.rawValue, actor, ok: true, message: confirmed ? "Approved by the person" : nil)
            return runner.status(result)
        } catch {
            log(id, action.rawValue, actor, ok: false, message: error.localizedDescription)
            throw error
        }
    }

    /// After starting, waits briefly until the project is listening or has crashed,
    /// so callers (agents especially) get a meaningful state back instead of "starting".
    private func waitUntilSettled(_ project: Project, _ runner: Runner, timeout: TimeInterval = 15) {
        guard project.port != nil else {
            usleep(500_000) // long enough to catch commands that fail right away
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = runner.status(project).state
            if state != .starting && state != .stopped { return }
            usleep(400_000)
        }
    }

    enum Authorization { case allowed, needsConfirmation }

    @discardableResult
    func authorize(_ action: Action, _ project: Project, _ actor: Actor) throws -> Authorization {
        guard actor.isAgent else { return .allowed }
        if action.requiresPerson {
            if project.agentPermission == .none { throw ControlError.notFound(project.id) }
            return .needsConfirmation
        }
        switch project.agentPermission {
        case .none:
            throw ControlError.notFound(project.id)
        case .read where action.needsControl:
            let error = ControlError.permissionDenied(action == .edit
                ? "'\(project.id)' only lets agents see its status, not change its configuration."
                : "'\(project.id)' only lets agents see its status, not start or stop it.")
            log(project.id, action.rawValue, actor, ok: false, message: error.localizedDescription)
            throw error
        case .confirm where action.needsControl:
            return .needsConfirmation
        default:
            return .allowed
        }
    }

    func log(_ id: String, _ action: String, _ actor: Actor, ok: Bool, message: String? = nil) {
        let entry = ActivityEntry(date: Date(), projectId: id, action: action, actor: actor.name, ok: ok, message: message, agent: actor.isAgent)
        guard var data = try? ProjectStore.lineEncoder.encode(entry) else { return }
        data.append(0x0A)
        try? paths.ensure()
        if let handle = try? FileHandle(forWritingTo: paths.activityFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: paths.activityFile)
        }
        trimActivity()
    }

    /// Keeps the activity log small: past 512 KB, only the newest 1000 entries survive.
    private func trimActivity(maxBytes: Int = 512_000, keep: Int = 1000) {
        let url = paths.activityFile
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(whereSeparator: \.isNewline).suffix(keep)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

extension ProjectStore {
    static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
