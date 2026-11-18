import ControlCore
import Foundation

/// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0), exposing project control as tools.
///
/// Whoever connects is always treated as an agent: per-project permissions apply. The agent's
/// name comes from `CCTL_ACTOR`, the known environment variables, or the client's `clientInfo`.
struct MCPServer {
    static let protocolVersion = "2025-06-18"
    static let version = "0.4.0"

    let service: ControlService
    var actor: Actor

    init(service: ControlService) {
        self.service = service
        let detected = Actor.detect()
        actor = detected.isAgent ? detected : Actor(name: "MCP agent", isAgent: true)
    }

    static let instructions = """
    Container Control turns the person's local development projects (Node apps, Docker Compose \
    stacks, single containers, custom commands) on and off on their Mac. Use list_projects to find \
    project ids and their state. Start a project before testing against its URL; stop it when you \
    no longer need it. Projects keep running after you finish. When the person asks to add the \
    project you are working on, call register_project with its absolute path; fix its settings \
    later with update_project. Open projects at their url (http://<name>.localhost when the \
    person uses domains); direct_url is the plain localhost port. Removing a project, publishing \
    it on the internet, changing agent permissions and turning domains on or off always wait for \
    the person's approval in the app; tell them you asked. Some projects only allow reading, \
    and some need the person to approve the action in the Container Control app, in which case \
    start_project/stop_project wait up to 90 seconds for their answer. Never try to bypass a \
    denied permission.
    """

    // MARK: Loop

    mutating func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let response = handle(message) { send(response) }
        }
    }

    mutating func handle(_ message: [String: Any]) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"] else { return nil } // notification

        func result(_ value: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        func error(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            if !Actor.detect().isAgent, let client = params["clientInfo"] as? [String: Any], let name = client["name"] as? String {
                actor = Actor(name: Self.friendlyName(name), isAgent: true)
            }
            let requested = params["protocolVersion"] as? String
            return result([
                "protocolVersion": requested ?? Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "container-control", "title": "Container Control", "version": Self.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return result(call(name, arguments))
        default:
            return error(-32601, "Method not found: \(method)")
        }
    }

    // MARK: Tools

    static var idSchema: [String: Any] { [
        "type": "object",
        "properties": ["id": ["type": "string", "description": "Project id, as returned by list_projects"]],
        "required": ["id"],
    ] }

    static var tools: [[String: Any]] { [
        [
            "name": "list_projects",
            "title": "List projects",
            "description": "Lists the local projects you may see, with id, name, kind, port, URL, state (running, starting, stopped, crashed, external, unknown) and your permission (read, control or confirm).",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "register_project",
            "title": "Register project",
            "description": "Registers a local project folder in Container Control, usually the one you are working in, so it can be started and stopped from the menu bar and by agents. Kind, name, start command, port and logo are detected from the folder (package.json, compose files, Dockerfile, .env); pass any of them to override what is detected. Fails if the folder is already registered, telling you its id. Check the returned start_command and port: a Node or custom project with no start command cannot be started.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path of the project folder"],
                    "name": ["type": "string", "description": "Display name. Default: package.json name or folder name"],
                    "kind": ["type": "string", "enum": ProjectKind.allCases.map(\.rawValue), "description": "node (launchd), compose, dockerfile or custom (any shell command, run by launchd)"],
                    "start_command": ["type": "string", "description": "Shell command that runs the project in the foreground, for node and custom kinds, e.g. 'pnpm dev'"],
                    "port": ["type": "integer", "description": "Port the project listens on; used to know when it is ready"],
                    "logo": ["type": "string", "description": "Absolute path to an image to use as the project's logo"],
                ],
                "required": ["path"],
            ],
            "annotations": ["destructiveHint": false],
        ],
        [
            "name": "update_project",
            "title": "Update project",
            "description": "Changes a registered project's configuration: name, kind, start/stop command, port, compose file, .localhost domain, environment variables or logo. Only the fields you pass change. Allowed when your permission on the project is control; with confirm, it waits up to 90 seconds for the person to approve. You cannot change permissions, publish to the internet or move the folder. Restart the project afterwards for runtime changes (command, port, env) to apply.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Project id"],
                    "name": ["type": "string"],
                    "kind": ["type": "string", "enum": ProjectKind.allCases.map(\.rawValue)],
                    "start_command": ["type": "string", "description": "Empty string removes it"],
                    "stop_command": ["type": "string", "description": "Empty string removes it"],
                    "port": ["type": "integer", "description": "0 removes it"],
                    "compose_file": ["type": "string", "description": "Relative to the project folder; empty string uses the default"],
                    "domain": ["type": "string", "description": "Name under .localhost: 'shop' serves the project at http://shop.localhost. Empty string goes back to the id."],
                    "env": [
                        "type": "object",
                        "description": "Variables to set; a null value removes that variable",
                        "additionalProperties": ["type": ["string", "null"]],
                    ],
                    "logo": ["type": "string", "description": "Absolute path to an image"],
                ],
                "required": ["id"],
            ],
            "annotations": ["destructiveHint": false, "idempotentHint": true],
        ],
        [
            "name": "project_status",
            "title": "Project status",
            "description": "Current state of one project: running, starting (process up, port not listening yet), stopped, crashed (exited with an error), external (port taken by another process) or unknown.",
            "inputSchema": idSchema,
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "start_project",
            "title": "Start project",
            "description": "Starts a project and returns its state. Already running projects are left as they are. May wait for the person to approve it in the app.",
            "inputSchema": idSchema,
            "annotations": ["destructiveHint": false, "idempotentHint": true],
        ],
        [
            "name": "stop_project",
            "title": "Stop project",
            "description": "Stops a project (and its child processes or containers). May wait for the person to approve it in the app.",
            "inputSchema": idSchema,
            "annotations": ["destructiveHint": true, "idempotentHint": true],
        ],
        [
            "name": "restart_project",
            "title": "Restart project",
            "description": "Stops and starts a project. May wait for the person to approve it in the app.",
            "inputSchema": idSchema,
            "annotations": ["destructiveHint": true],
        ],
        [
            "name": "project_logs",
            "title": "Project logs",
            "description": "Returns the last lines of a project's output (stdout and stderr, or docker logs). Useful to see why a project crashed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Project id"],
                    "lines": ["type": "integer", "description": "How many lines, 1 to 500. Default 100.", "minimum": 1, "maximum": 500],
                ],
                "required": ["id"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "project_activity",
            "title": "Activity log",
            "description": "Who started, stopped, changed, published or removed what, and when (the person, the app, the terminal or an agent), newest first, including failed attempts and why. Omit id for all projects.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Project id; omit for every project"],
                    "limit": ["type": "integer", "description": "Entries, 1 to 200. Default 30.", "minimum": 1, "maximum": 200],
                ],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "list_requests",
            "title": "Pending approvals",
            "description": "Agent requests waiting for the person to approve or deny them in the app. Only the person can answer them.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "detect_project",
            "title": "Detect project",
            "description": "Shows what register_project would detect in a folder (kind, name, start command, port, logo) without registering it, and whether it is already registered.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "Absolute path of the folder"]],
                "required": ["path"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "system_status",
            "title": "System status",
            "description": "Whether the pieces Container Control relies on work: the app (needed for approvals), .localhost domains, Docker, cloudflared (for publishing), and where node, npm, pnpm and docker are found.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "remove_project",
            "title": "Remove project",
            "description": "Stops a project and removes it from Container Control (its folder is not touched). Always waits up to 90 seconds for the person to approve it in the app.",
            "inputSchema": idSchema,
            "annotations": ["destructiveHint": true],
        ],
        [
            "name": "publish_project",
            "title": "Publish on the internet",
            "description": "Gives a project a throwaway public https URL (https://<random-words>.trycloudflare.com, a Cloudflare Quick Tunnel) that anyone with it can open. Always waits up to 90 seconds for the person to approve it in the app, then about 10-20 seconds until the address works. The address changes every time it is published and stops working when unpublished or when the Mac restarts. Returns public_url.",
            "inputSchema": idSchema,
            "annotations": ["destructiveHint": false, "openWorldHint": true],
        ],
        [
            "name": "unpublish_project",
            "title": "Stop publishing",
            "description": "Closes a project's public trycloudflare.com address for good. Always waits up to 90 seconds for the person to approve it in the app.",
            "inputSchema": idSchema,
            "annotations": ["destructiveHint": true, "idempotentHint": true],
        ],
        [
            "name": "set_agent_permission",
            "title": "Set agent permission",
            "description": "Asks to change what agents may do with a project: none (hidden), read (status and logs), control (start, stop, update) or confirm (each action needs approval). Always waits up to 90 seconds for the person to approve it in the app.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Project id"],
                    "permission": ["type": "string", "enum": AgentPermission.allCases.map(\.rawValue)],
                ],
                "required": ["id", "permission"],
            ],
            "annotations": ["destructiveHint": false, "idempotentHint": true],
        ],
        [
            "name": "set_domains",
            "title": "Turn .localhost domains on or off",
            "description": "Turns on or off the proxy that serves every project at http://<name>.localhost. Always waits up to 90 seconds for the person to approve it in the app.",
            "inputSchema": [
                "type": "object",
                "properties": ["enabled": ["type": "boolean"]],
                "required": ["enabled"],
            ],
            "annotations": ["destructiveHint": false, "idempotentHint": true],
        ],
    ] }

    func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        do {
            let text: String
            switch name {
            case "list_projects":
                service.syncPublished()
                let projects = try service.projects(actor: actor)
                let statuses = service.statuses(projects)
                text = try json(projects.map { summary($0, statuses[$0.id]) })
            case "project_status":
                service.syncPublished()
                let project = try service.project(try id(arguments), actor: actor)
                text = try json(summary(project, service.status(project), detailed: true))
            case "start_project", "stop_project", "restart_project":
                let id = try id(arguments)
                let status: ProjectStatus = switch name {
                case "start_project": try service.start(id, actor: actor)
                case "stop_project": try service.stop(id, actor: actor)
                default: try service.restart(id, actor: actor)
                }
                text = try json(summary(try service.project(id, actor: actor), status))
            case "register_project":
                text = try register(arguments)
            case "update_project":
                let id = try id(arguments)
                let project = try service.update(id, try changes(arguments), actor: actor)
                text = try json(summary(project, service.status(project), detailed: true))
            case "project_logs":
                let lines = min(max((arguments["lines"] as? Int) ?? 100, 1), 500)
                let output = try service.logText(try id(arguments), tail: lines, actor: actor)
                text = output.isEmpty ? "(no logs)" : String(output.suffix(60_000))
            case "project_activity":
                text = try json(activity(arguments))
            case "list_requests":
                let visible = Set(try service.projects(actor: actor).map(\.id))
                text = try json(service.pendingRequests().filter { visible.contains($0.projectId) || $0.projectId == ControlService.systemId }.map { request in
                    var item: [String: Any] = [
                        "id": request.id, "project": request.projectId, "action": request.action, "agent": request.actor,
                        "expires_at": ISO8601DateFormatter().string(from: request.expiresAt),
                    ]
                    if let changes = request.changes { item["changes"] = changes.summary }
                    if let value = request.value { item["value"] = value }
                    return item
                })
            case "detect_project":
                guard let path = arguments["path"] as? String, path.hasPrefix("/") || path.hasPrefix("~") else {
                    throw ControlError.invalid("'path' must be an absolute path.")
                }
                let draft = try Detector.detect(folder: path)
                var item = summary(draft, nil, detailed: true)
                item.removeValue(forKey: "state")
                item.removeValue(forKey: "url")
                item["registered_as"] = (try service.store.all()).first { $0.path == draft.path }?.id ?? NSNull()
                text = try json(item)
            case "system_status":
                text = try json(systemStatus())
            case "remove_project":
                let id = try id(arguments)
                try service.remove(id, actor: actor)
                text = "Removed '\(id)'. The project folder was not touched."
            case "publish_project", "unpublish_project":
                let id = try id(arguments)
                let project = name == "publish_project"
                    ? try service.publish(id, actor: actor)
                    : try service.unpublish(id, actor: actor)
                text = try json(summary(project, service.status(project)))
            case "set_agent_permission":
                guard let raw = arguments["permission"] as? String, let permission = AgentPermission(rawValue: raw) else {
                    throw ControlError.invalid("'permission' must be none, read, control or confirm.")
                }
                let project = try service.setAgentPermission(try id(arguments), permission, actor: actor)
                // With "none" the agent can no longer see it; report without failing.
                text = project.agentPermission == .none ? "Permission changed to none: you will no longer see this project." : try json(summary(project, service.status(project)))
            case "set_domains":
                guard let enabled = arguments["enabled"] as? Bool else { throw ControlError.invalid("Missing 'enabled' (true or false).") }
                try service.setDomains(enabled, actor: actor)
                text = try json(systemStatus())
            default:
                return ["content": [["type": "text", "text": "Unknown tool: \(name)"]], "isError": true]
            }
            return ["content": [["type": "text", "text": text]]]
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    private func register(_ arguments: [String: Any]) throws -> String {
        guard let path = arguments["path"] as? String, !path.isEmpty else { throw ControlError.invalid("Missing the 'path' argument.") }
        guard path.hasPrefix("/") || path.hasPrefix("~") else {
            throw ControlError.invalid("'path' must be an absolute path.")
        }
        let project = try service.add(folder: path, actor: actor, logo: arguments["logo"] as? String) { draft in
            if let name = arguments["name"] as? String, !name.isEmpty { draft.name = name }
            if let raw = arguments["kind"] as? String {
                guard let kind = ProjectKind(rawValue: raw) else { throw ControlError.invalid("Invalid 'kind': \(raw)") }
                draft.kind = kind
            }
            if let command = arguments["start_command"] as? String, !command.isEmpty { draft.startCommand = command }
            if let port = arguments["port"] as? Int { draft.port = port }
        }
        var item = summary(project, service.status(project))
        item["start_command"] = project.startCommand ?? NSNull()
        if project.kind.usesLaunchd && project.startCommand == nil {
            item["warning"] = "No start command was detected, so it cannot be started yet. Ask the person to set one in Container Control."
        }
        return try json(item)
    }

    private func activity(_ arguments: [String: Any]) throws -> [[String: Any]] {
        let visible = Set(try service.projects(actor: actor).map(\.id)).union([ControlService.systemId])
        let limit = min(max((arguments["limit"] as? Int) ?? 30, 1), 200)
        let projectId = arguments["id"] as? String
        if let projectId { _ = try service.project(projectId, actor: actor) } // hidden projects stay hidden
        let entries = service.activity(limit: 2000, projectId: projectId).filter { visible.contains($0.projectId) }
        let formatter = ISO8601DateFormatter()
        return entries.suffix(limit).reversed().map { entry in
            var item: [String: Any] = [
                "date": formatter.string(from: entry.date), "project": entry.projectId, "action": entry.action,
                "by": entry.actor, "agent": entry.isAgent, "ok": entry.ok,
            ]
            if let message = entry.message { item["message"] = message }
            return item
        }
    }

    private func systemStatus() -> [String: Any] {
        let proxy = service.proxy.state()
        var status: [String: Any] = [
            "app_running": service.isAppRunning(),
            "domains": [
                "enabled": proxy.installed, "running": proxy.running,
                "port_80_taken_by": proxy.portTakenBy ?? NSNull(),
            ] as [String: Any],
        ]
        let docker = try? Shell.tool("docker", ["info", "--format", "{{.ServerVersion}} {{.OperatingSystem}}"], timeout: 10)
        status["docker"] = docker?.ok == true ? docker!.stdout.trimmingCharacters(in: .whitespacesAndNewlines) as Any : "not available"
        if let cli = QuickTunnel.cli {
            let version = (try? Shell.run(cli, ["--version"], timeout: 5))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            status["cloudflared"] = version.isEmpty ? cli : version
        } else {
            status["cloudflared"] = "not installed (brew install cloudflared)"
        }
        var tools: [String: Any] = [:]
        for tool in ["node", "npm", "pnpm", "bun", "docker"] {
            let found = try? Shell.tool("which", [tool], timeout: 5)
            tools[tool] = found?.ok == true ? found!.stdout.trimmingCharacters(in: .whitespacesAndNewlines) as Any : NSNull()
        }
        status["tools"] = tools
        return status
    }

    private func changes(_ arguments: [String: Any]) throws -> ProjectChanges {
        var changes = ProjectChanges()
        changes.name = arguments["name"] as? String
        if let raw = arguments["kind"] as? String {
            guard let kind = ProjectKind(rawValue: raw) else { throw ControlError.invalid("Invalid 'kind': \(raw)") }
            changes.kind = kind
        }
        changes.startCommand = arguments["start_command"] as? String
        changes.stopCommand = arguments["stop_command"] as? String
        changes.port = arguments["port"] as? Int
        changes.composeFile = arguments["compose_file"] as? String
        changes.hostname = arguments["domain"] as? String
        changes.logo = arguments["logo"] as? String
        if let env = arguments["env"] as? [String: Any] {
            let set = env.compactMapValues { $0 as? String }
            let removed = env.filter { $0.value is NSNull }.map(\.key)
            if !set.isEmpty { changes.setEnv = set }
            if !removed.isEmpty { changes.removeEnv = removed }
        }
        guard !changes.isEmpty else { throw ControlError.invalid("Nothing to change: pass at least one field besides 'id'.") }
        return changes
    }

    private func id(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments["id"] as? String, !id.isEmpty else { throw ControlError.invalid("Missing the 'id' argument.") }
        return id
    }

    private func summary(_ project: Project, _ status: ProjectStatus?, detailed: Bool = false) -> [String: Any] {
        var item: [String: Any] = [
            "id": project.id,
            "name": project.name,
            "kind": project.kind.rawValue,
            "path": project.path,
            "state": status?.state.rawValue ?? "unknown",
            "permission": project.agentPermission.rawValue,
        ]
        if let port = project.port {
            item["port"] = port
            item["url"] = service.webURL(project)?.absoluteString
            // Some tools (or a project's own CORS/OAuth settings) need the plain address.
            item["direct_url"] = "http://localhost:\(port)"
        }
        if let detail = status?.detail { item["detail"] = detail }
        if let hostname = project.hostname { item["domain"] = "\(hostname).localhost" }
        if let publicURL = project.publicURL { item["public_url"] = publicURL }
        if detailed {
            item["start_command"] = project.startCommand ?? NSNull()
            item["stop_command"] = project.stopCommand ?? NSNull()
            item["compose_file"] = project.composeFile ?? NSNull()
            // Values may be secrets: only agents that may change the project see them.
            if project.agentPermission == .read { item["env_keys"] = project.env.keys.sorted() } else { item["env"] = project.env }
        }
        return item
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    static func friendlyName(_ client: String) -> String {
        switch client.lowercased() {
        case "claude-ai", "claude-desktop": "Claude Desktop"
        case "claude-code": "Claude Code"
        case "cursor", "cursor-vscode": "Cursor"
        case let name where name.contains("codex"): "Codex"
        default: client
        }
    }
}
