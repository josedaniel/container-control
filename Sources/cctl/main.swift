import ControlCore
import Foundation

let usage = """
cctl — start and stop the projects on your Mac

USAGE
  cctl <command> [arguments] [options]

PROJECTS
  cctl list [--json]                     Projects and their state (alias: ls)
  cctl status [<id>] [--json]            State of one project, or all of them
  cctl show <id> [--json]                Full configuration of a project (alias: info)
  cctl start <id> [--json]               Start a project
  cctl stop <id> [--json]                Stop a project
  cctl restart <id> [--json]             Restart a project
  cctl logs <id> [-n 200] [-f]           Last lines of output (-f/--follow keeps reading)
  cctl activity [<id>] [-n 30] [--json]  Who started, stopped or changed what

CONFIGURATION
  cctl detect <folder> [--json]          Show what would be detected, without saving
  cctl add [<folder>] [options] [--json] Register a project (defaults to the current folder)
  cctl set <id> [options] [--json]       Change its configuration (alias: edit)
  cctl remove <id>                       Stop and unregister it; the folder is kept (alias: rm)

DOMAINS AND SHARING
  cctl proxy [status]                    Whether http://<id>.localhost is working
  cctl proxy install|uninstall           Turn .localhost domains on or off
  cctl proxy run [--port 80]             Run the proxy in the foreground (launchd does this)
  cctl publish <id> [--json]             Temporary public https://….trycloudflare.com link
  cctl unpublish <id>                    Close that link

AGENTS
  cctl mcp                               MCP server over stdio for AI agents
  cctl requests [--json]                 Agent requests waiting for your approval
  cctl approve|deny <request>            Answer a request (not available to agents)
  cctl whoami                            Who cctl thinks is calling (you or an agent)

SYSTEM
  cctl doctor [--refresh]                Check config, tools and Docker (--refresh re-reads PATH)
  cctl --help                            This help (also -h, after any command)

OPTIONS FOR add / set
  --name <name>                 Display name
  --id <id>                     Identifier, add only (default: from the folder name)
  --kind <kind>                 node, compose, dockerfile or custom
  --start <command>             Start command (node and custom)
  --stop <command>              Stop command (optional)
  --port <number>               Port it listens on; "none" clears it
  --compose-file <file>         Compose file, relative to the folder
  --domain <name>               Serve it at http://<name>.localhost (dots allowed)
  --logo <image>                Image to copy in as its logo
  --env KEY=value               Set an environment variable (repeatable)
  --unset-env KEY               Remove an environment variable (repeatable)
  --agents <permission>         What AI agents may do: none, read, control, confirm
  An empty value (--start "", --domain "") clears that setting.
  Options accept --key value or --key=value.

ENVIRONMENT
  CCTL_HOME              Config folder (default ~/.config/container-control)
  CCTL_ACTOR             Name to record for this caller; marks it as an agent
  CCTL_CONFIRM_TIMEOUT   Seconds an agent waits for your approval (default 90)
  Projects started by cctl see CCTL_PROJECT=<id> and, if they have a port, PORT.

AGENTS AND PERMISSIONS
  Claude Code, Codex and Gemini CLI are detected automatically; other agents should set
  CCTL_ACTOR. Agents may register new projects and, depending on each project's
  permission, view (read), start, stop, restart and change it (control). With confirm,
  every action waits until you approve it in the app or with `cctl approve`. Removing,
  publishing, changing permissions and turning domains on or off always wait for you.

  Claude Code:     claude mcp add --scope user container-control -- cctl mcp

EXIT STATUS
  0 on success, 1 on error or when a project ends up in error after start/restart.
  `cctl logs` returns the exit status of the underlying log reader.
"""

setvbuf(stdout, nil, _IOLBF, 0)

let service = ControlService()
let actor = Actor.detect()

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func icon(_ state: RunState) -> String {
    switch state {
    case .running: "●"
    case .starting: "◐"
    case .stopped: "○"
    case .crashed: "✕"
    case .external: "◆"
    case .unknown: "?"
    }
}

func label(_ state: RunState) -> String {
    switch state {
    case .running: "running"
    case .starting: "starting"
    case .stopped: "stopped"
    case .crashed: "error"
    case .external: "external"
    case .unknown: "unknown"
    }
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

struct Row: Encodable {
    let project: Project
    let status: ProjectStatus
}

func rows(_ projects: [Project]) -> [Row] {
    let statuses = service.statuses(projects)
    return projects.map { Row(project: $0, status: statuses[$0.id]!) }
}

func printTable(_ rows: [Row]) {
    guard !rows.isEmpty else {
        print("No projects yet. Add one with `cctl add <folder>`.")
        return
    }
    let idWidth = max(4, rows.map(\.project.id.count).max() ?? 0) + 2
    let nameWidth = max(6, rows.map(\.project.name.count).max() ?? 0) + 2
    print(pad("", 2) + pad("ID", idWidth) + pad("NAME", nameWidth) + pad("KIND", 12) + pad("STATE", 14) + "PORT")
    for row in rows {
        let port = row.project.port.map(String.init) ?? "-"
        print(icon(row.status.state) + " " + pad(row.project.id, idWidth) + pad(row.project.name, nameWidth)
              + pad(row.project.kind.rawValue, 12) + pad(label(row.status.state), 14) + port)
        if let detail = row.status.detail { print("    ↳ \(detail)") }
    }
}

func printStatus(_ status: ProjectStatus, _ project: Project) {
    var line = "\(icon(status.state)) \(project.name) (\(project.id)): \(label(status.state))"
    if status.isActive, let url = service.webURL(project) { line += " · \(url.absoluteString)" }
    if let pid = status.pid { line += " · pid \(pid)" }
    print(line)
    if let detail = status.detail { print("  ↳ \(detail)") }
}

func printProject(_ project: Project) {
    print("""
    id:        \(project.id)
    name:      \(project.name)
    folder:    \(project.path)
    kind:      \(project.kind.rawValue)
    start:     \(project.startCommand ?? project.kind.defaultStartDescription)
    port:      \(project.port.map(String.init) ?? "-")
    logo:      \(project.logo ?? "-")
    agents:    \(project.agentPermission.rawValue)
    """)
    if let url = service.webURL(project) { print("url:       \(url.absoluteString)") }
    if let publicURL = project.publicURL { print("public:    \(publicURL)") }
    if let stop = project.stopCommand { print("stop:      \(stop)") }
    if let file = project.composeFile { print("compose:   \(file)") }
    if !project.env.isEmpty {
        print("env:       " + project.env.keys.sorted().joined(separator: ", "))
    }
}

extension ProjectKind {
    var defaultStartDescription: String {
        switch self {
        case .compose: "docker compose up -d"
        case .dockerfile: "docker build + docker run"
        case .node, .custom: "-"
        }
    }
}

/// The options of `add` and `set` that anyone (agents included) may change.
func changes(from args: Arguments) throws -> ProjectChanges {
    var changes = ProjectChanges()
    changes.name = args.value("name")
    if let kind = args.value("kind") {
        guard let parsed = ProjectKind(rawValue: kind) else { throw CLIError.usage("Invalid --kind: \(kind)") }
        changes.kind = parsed
    }
    changes.startCommand = args.value("start")
    changes.stopCommand = args.value("stop")
    if let port = args.value("port") {
        if port.isEmpty || port == "none" { changes.port = 0 } else {
            guard let n = Int(port) else { throw CLIError.usage("--port must be a number") }
            changes.port = n
        }
    }
    changes.composeFile = args.value("compose-file")
    changes.hostname = args.value("domain")
    var setEnv: [String: String] = [:]
    for pair in args.values("env") {
        guard let eq = pair.firstIndex(of: "=") else { throw CLIError.usage("--env expects KEY=value") }
        setEnv[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
    }
    if !setEnv.isEmpty { changes.setEnv = setEnv }
    if !args.values("unset-env").isEmpty { changes.removeEnv = args.values("unset-env") }
    changes.logo = args.value("logo")
    return changes
}

func agentPermission(from args: Arguments) throws -> AgentPermission? {
    guard let agents = args.value("agents") else { return nil }
    guard let permission = AgentPermission(rawValue: agents) else {
        throw CLIError.usage("--agents must be none, read, control or confirm")
    }
    return permission
}

func apply(_ args: Arguments, to project: inout Project) throws {
    let changes = try changes(from: args)
    changes.apply(to: &project)
    if let permission = try agentPermission(from: args) { project.agentPermission = permission }
}

func run(_ raw: [String]) throws -> Int32 {
    guard let command = raw.first, !["help", "--help", "-h"].contains(command) else {
        print(usage)
        return 0
    }
    let args = try Arguments(Array(raw.dropFirst()))
    if args.flag("help") {
        print(usage)
        return 0
    }

    switch command {
    case "list", "ls":
        service.syncPublished()
        let result = rows(try service.projects(actor: actor))
        if args.flag("json") { try printJSON(result) } else { printTable(result) }

    case "status":
        service.syncPublished()
        if let id = args.positionals.first {
            let project = try service.project(id, actor: actor)
            let status = service.status(project)
            if args.flag("json") { try printJSON(status) } else { printStatus(status, project) }
        } else {
            let result = rows(try service.projects(actor: actor))
            if args.flag("json") { try printJSON(result.map(\.status)) } else { printTable(result) }
        }

    case "start", "stop", "restart":
        let id = try args.positional(0, "id")
        let project = try service.project(id, actor: actor)
        if !args.flag("json") {
            let verb = ["start": "Starting", "stop": "Stopping", "restart": "Restarting"][command]!
            print("\(verb) \(project.name)…")
        }
        let status: ProjectStatus = switch command {
        case "start": try service.start(id, actor: actor)
        case "stop": try service.stop(id, actor: actor)
        default: try service.restart(id, actor: actor)
        }
        if args.flag("json") { try printJSON(status) } else { printStatus(status, (try? service.store.get(id)) ?? project) }
        if status.state == .crashed { return 1 }

    case "logs":
        let id = try args.positional(0, "id")
        let invocation = try service.logs(id, tail: try args.int("tail") ?? 200, follow: args.flag("follow"), actor: actor)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        if let cwd = invocation.cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env = invocation.environment { process.environment = env }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus

    case "activity":
        let entries = service.activity(limit: try args.int("tail") ?? 30, projectId: args.positionals.first)
        if args.flag("json") { try printJSON(entries); break }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if entries.isEmpty { print("No activity yet.") }
        for entry in entries {
            var line = "\(formatter.string(from: entry.date))  \(entry.ok ? "✓" : "✕") \(pad(entry.action, 18)) \(pad(entry.projectId, 20)) \(entry.actor)"
            if let message = entry.message { line += " — \(message)" }
            print(line)
        }

    case "detect":
        let project = try Detector.detect(folder: try args.positional(0, "folder"))
        if args.flag("json") { try printJSON(project) } else { printProject(project) }

    case "add":
        let folder = args.positionals.first ?? "."
        let stored = try service.add(folder: folder, actor: actor, logo: args.value("logo")) { draft in
            if let id = args.value("id") { draft.id = id }
            try apply(args, to: &draft)
        }
        if args.flag("json") { try printJSON(stored) } else {
            print("Project added:\n")
            printProject(stored)
            if stored.kind.usesLaunchd && stored.startCommand == nil {
                print("\n⚠︎ No start command was detected. Set one with: cctl set \(stored.id) --start \"...\"")
            }
        }

    case "set", "edit":
        let id = try args.positional(0, "id")
        var project = try service.update(id, try changes(from: args), actor: actor)
        if let permission = try agentPermission(from: args) {
            project = try service.setAgentPermission(id, permission, actor: actor)
        }
        if args.flag("json") { try printJSON(project) } else { printProject(project) }

    case "publish", "unpublish":
        let id = try args.positional(0, "id")
        if command == "publish" {
            if !args.flag("json") { print("Opening a Cloudflare tunnel (takes a few seconds)…") }
            let project = try service.publish(id, actor: actor)
            if args.flag("json") { try printJSON(project); break }
            print("Published at \(project.publicURL ?? "?")")
            print("Anyone with that link can see it. It changes every time you publish and stops working with `cctl unpublish \(id)` or when the Mac restarts.")
        } else {
            try service.unpublish(id, actor: actor)
            print("Unpublished. That link no longer works.")
        }

    case "show", "info":
        service.syncPublished()
        let project = try service.project(try args.positional(0, "id"), actor: actor)
        if args.flag("json") { try printJSON(project) } else { printProject(project) }

    case "remove", "rm":
        let id = try args.positional(0, "id")
        try service.remove(id, actor: actor)
        print("Removed '\(id)'. The project folder was not touched.")

    case "mcp":
        var server = MCPServer(service: service)
        server.run()

    case "requests":
        let requests = service.pendingRequests()
        if args.flag("json") { try printJSON(requests); break }
        if requests.isEmpty { print("No pending requests.") }
        for request in requests {
            var line = "\(request.id)  \(request.actor) wants to \(Action(rawValue: request.action)?.verb ?? request.action)"
            if request.projectId != ControlService.systemId { line += " \(request.projectId)" }
            if let value = request.value { line += request.action == Action.domains.rawValue ? " (\(value == "on" ? "turn on" : "turn off"))" : " to “\(value)”" }
            if let changes = request.changes { line += ": \(changes.summary)" }
            print(line)
        }

    case "approve", "deny":
        if actor.isAgent { throw ControlError.permissionDenied("Agents cannot approve requests.") }
        try service.resolve(try args.positional(0, "request"), approve: command == "approve")
        print(command == "approve" ? "Approved." : "Denied.")

    case "proxy":
        let agent = service.proxy
        switch args.positionals.first ?? "status" {
        case "run":
            let port = try args.int("port").map(UInt16.init) ?? ProxyServer.defaultPort
            try ProxyServer(service: service, port: port).run()
        case "install":
            try service.setDomains(true, actor: actor)
            usleep(800_000)
            let state = agent.state()
            print(state.running
                ? "Proxy installed. Your projects are at http://<id>.localhost (index at http://localhost)."
                : "Proxy installed, but it is not running. Check \(agent.logFile.path)")
        case "uninstall":
            try service.setDomains(false, actor: actor)
            print("Proxy uninstalled. Projects open at localhost:<port> again.")
        case "status":
            let state = agent.state()
            if !state.installed { print("○ Proxy not installed. Install it with `cctl proxy install`.") }
            else if state.running { print("● Proxy running: http://<id>.localhost") }
            else { print("✕ Proxy installed but stopped\(state.portTakenBy.map { ": port 80 is used by \($0)" } ?? ""). Check \(agent.logFile.path)") }
        default:
            throw CLIError.usage("Usage: cctl proxy [status|install|uninstall|run [--port N]]")
        }

    case "whoami":
        print("\(actor.name)\(actor.isAgent ? " (agent)" : "")")

    case "doctor":
        let path = LoginEnvironment.path(paths: service.paths, refresh: args.flag("refresh"))
        print("Config:   \(service.paths.base.path)")
        print("Actor:    \(actor.name)\(actor.isAgent ? " (agent)" : "")")
        for tool in ["node", "npm", "pnpm", "bun", "docker"] {
            let found = try? Shell.tool("which", [tool], timeout: 5)
            let location = found?.ok == true ? found!.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "not found"
            print(pad(tool + ":", 10) + location)
        }
        let docker = try? Shell.tool("docker", ["info", "--format", "{{.ServerVersion}} · {{.OperatingSystem}}"], timeout: 10)
        print("Docker:   " + (docker?.ok == true ? docker!.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "not available"))
        if args.flag("refresh") { print("PATH:     \(path)") }

    default:
        throw CLIError.usage("Unknown command: \(command). Use `cctl --help`.")
    }
    return 0
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
