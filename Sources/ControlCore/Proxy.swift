import Foundation
import Network

/// Serves every project at `http://<id>.localhost`.
///
/// It reads the Host header of the first request on each connection and then pipes raw bytes
/// both ways to `localhost:<port>`. Browsers open separate connections per host, so one
/// connection always belongs to one project, and WebSocket upgrades (Vite HMR), streaming
/// and keep-alive pass through untouched.
///
/// Binding port 80 without root is only allowed on all interfaces, so the server drops any
/// connection that does not come from this Mac.
public final class ProxyServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 80

    let service: ControlService
    let port: UInt16
    private let queue = DispatchQueue(label: "container-control.proxy")
    private var listener: NWListener?
    private var routes: (modified: Date?, projects: [String: Project]) = (nil, [:])

    public init(service: ControlService, port: UInt16 = defaultPort) {
        self.service = service
        self.port = port
    }

    /// Starts listening and never returns.
    public func run() throws -> Never {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ControlError.invalid("Invalid port: \(port)") }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [port] state in
            switch state {
            case .ready:
                print("Proxy listening on port \(port): http://<project>.localhost")
            case .failed(let error):
                print("The proxy could not listen on port \(port): \(error)")
                exit(1)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        dispatchMain()
    }

    // MARK: Connections

    private func accept(_ client: NWConnection) {
        guard Self.isLoopback(client.endpoint) else {
            client.cancel()
            return
        }
        client.start(queue: queue)
        readHead(client, Data())
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
        default: return false
        }
    }

    /// Reads until the end of the first request's headers.
    private func readHead(_ client: NWConnection, _ buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                route(client, buffer, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buffer.count > 65_536 {
                client.cancel()
            } else {
                readHead(client, buffer)
            }
        }
    }

    private func route(_ client: NWConnection, _ buffer: Data, head: String) {
        let host = Self.host(in: head)

        guard host.hasSuffix(".localhost") else {
            respond(client, status: "200 OK", page: index())
            return
        }
        guard let project = Hostnames.project(forHost: host, in: Array(projects().values)) else {
            respond(client, status: "404 Not Found", page: index(missing: host))
            return
        }
        connect(client, buffer, to: project)
    }

    /// Tunnels the connection to the project's port.
    private func connect(_ client: NWConnection, _ buffer: Data, to project: Project) {
        guard let port = project.port, let upstreamPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            respond(client, status: "502 Bad Gateway", page: Page.message(
                title: project.name, text: "This project has no port set. Add one in Container Control."))
            return
        }

        // "localhost" lets Network.framework try ::1 and 127.0.0.1, since dev servers bind either.
        let upstream = NWConnection(host: "localhost", port: upstreamPort, using: .tcp)
        let settled = Flag()
        upstream.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard settled.set() else { return }
                upstream.send(content: buffer, completion: .contentProcessed { _ in })
                let pair = Pair(client, upstream)
                pipe(from: client, to: upstream, pair)
                pipe(from: upstream, to: client, pair)
            case .waiting, .failed:
                guard settled.set() else { return }
                upstream.cancel()
                // 503, not 502: Cloudflare replaces 502s from the origin with its own error page.
                respond(client, status: "503 Service Unavailable", page: unavailable(project))
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// Copies bytes one way, closing that direction on EOF and both connections once both
    /// directions are done or anything fails.
    private func pipe(from source: NWConnection, to destination: NWConnection, _ pair: Pair) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { pair.cancel(); return }
                    if isComplete { self.finish(destination, pair) } else { self.pipe(from: source, to: destination, pair) }
                })
            } else if error != nil {
                pair.cancel()
            } else if isComplete {
                finish(destination, pair)
            } else {
                pipe(from: source, to: destination, pair)
            }
        }
    }

    private func finish(_ destination: NWConnection, _ pair: Pair) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            pair.directionDone()
        })
    }

    private func respond(_ client: NWConnection, status: String, page: String) {
        let body = Data(page.utf8)
        let retry = status.hasPrefix("503") ? "Retry-After: 3\r\n" : ""
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n\(retry)Connection: close\r\n\r\n"
        client.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            client.cancel()
        })
    }

    // MARK: Routing

    static func host(in head: String) -> String {
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "host" else { continue }
            var host = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if host.hasPrefix("[") { return host } // IPv6 literal
            if let portColon = host.lastIndex(of: ":") { host = String(host[..<portColon]) }
            return host.hasSuffix(".") ? String(host.dropLast()) : host
        }
        return ""
    }

    /// `acme-admin.localhost` → `acme-admin`. Deeper names (`api.acme-admin.localhost`)
    /// go to the same project.
    public static func projectId(forHost host: String) -> String? {
        guard host.hasSuffix(".localhost") else { return nil }
        return host.dropLast(".localhost".count).split(separator: ".").last.map(String.init)
    }

    private func projects() -> [String: Project] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: service.paths.projectsFile.path))?[.modificationDate] as? Date
        if modified != routes.modified || routes.projects.isEmpty {
            let all = (try? service.store.all()) ?? []
            routes = (modified, Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        }
        return routes.projects
    }

    // MARK: Pages

    private func unavailable(_ project: Project) -> String {
        if service.status(project).isActive {
            return Page.message(title: project.name, text: "It is running but not answering on port \(project.port ?? 0) yet. This page reloads by itself.", refresh: 2)
        }
        return Page.message(title: project.name, text: "It is stopped. Start it from Container Control or ask your agent to; this page reloads by itself.", refresh: 3)
    }

    private func index(missing host: String? = nil) -> String {
        let projects = projects().values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let statuses = service.statuses(projects)
        var rows = ""
        for project in projects where project.port != nil {
            let on = statuses[project.id]?.isActive == true
            let name = project.hostname ?? project.id
            rows += "<li><a href=\"http://\(name).localhost\">\(Page.escape(project.name))</a>"
                + "<span class=\"\(on ? "on" : "off")\">\(on ? "running" : "stopped")</span><code>\(name).localhost</code></li>"
        }
        let intro = host.map { "There is no project at <code>\(Page.escape($0))</code>. These are the ones there are:" }
            ?? "Your projects in Container Control:"
        return Page.wrap(title: "Container Control", body: "<p>\(intro)</p><ul>\(rows.isEmpty ? "<li>No projects with a port yet.</li>" : rows)</ul>")
    }
}

// MARK: - Helpers

/// One-shot flag, safe to use from the proxy's serial queue callbacks.
private final class Flag: @unchecked Sendable {
    private var value = false
    func set() -> Bool {
        if value { return false }
        value = true
        return true
    }
}

/// A client/upstream pair, cancelled together once both directions finish.
private final class Pair: @unchecked Sendable {
    let a: NWConnection
    let b: NWConnection
    private var done = 0

    init(_ a: NWConnection, _ b: NWConnection) {
        self.a = a
        self.b = b
    }

    func directionDone() {
        done += 1
        if done >= 2 { cancel() }
    }

    func cancel() {
        a.cancel()
        b.cancel()
    }
}

enum Page {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func message(title: String, text: String, refresh: Int? = nil) -> String {
        wrap(title: title, body: "<p>\(escape(text))</p>", refresh: refresh)
    }

    static func wrap(title: String, body: String, refresh: Int? = nil) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        \(refresh.map { "<meta http-equiv=\"refresh\" content=\"\($0)\">" } ?? "")
        <title>\(escape(title))</title><style>
        :root{color-scheme:light dark;--fg:#1d1d1f;--muted:#6e6e73;--bg:#f5f5f7;--card:#fff;--line:#e5e5ea}
        @media (prefers-color-scheme:dark){:root{--fg:#f5f5f7;--muted:#a1a1a6;--bg:#1c1c1e;--card:#2c2c2e;--line:#3a3a3c}}
        body{font:15px/1.5 -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg);margin:0;padding:48px 16px}
        main{max-width:560px;margin:auto;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:28px 32px}
        h1{font-size:20px;margin:0 0 8px}p{color:var(--muted)}ul{list-style:none;padding:0;margin:16px 0 0}
        li{display:flex;gap:10px;align-items:center;padding:10px 0;border-top:1px solid var(--line)}
        a{color:inherit;font-weight:600;text-decoration:none}a:hover{text-decoration:underline}
        code{margin-left:auto;color:var(--muted);font-size:13px}.on,.off{font-size:12px}.on{color:#30a46c}.off{color:var(--muted)}
        </style></head><body><main><h1>\(escape(title))</h1>\(body)</main></body></html>
        """
    }
}

// MARK: - launchd agent

/// Runs `cctl proxy run` as a login-time launchd agent, so domains work without the app open.
public struct ProxyAgent: Sendable {
    public static let label = "com.containercontrol.proxy"
    public let paths: Paths

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    var plistURL: URL { paths.launchAgentsDir.appendingPathComponent("\(Self.label).plist") }
    var domain: String { "gui/\(getuid())" }
    public var logFile: URL { paths.logsDir.appendingPathComponent("proxy.log") }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// The `cctl` to run: the one inside the app bundle when there is one, else this process
    /// (when it is cctl), else ~/.local/bin/cctl.
    public static var defaultExecutable: String {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "cctl") { return bundled.resolvingSymlinksInPath().path }
        if let me = Bundle.main.executableURL?.resolvingSymlinksInPath(), me.lastPathComponent == "cctl" { return me.path }
        let appBundled = "/Applications/Container Control.app/Contents/MacOS/cctl"
        let userBundled = NSHomeDirectory() + "/Applications/Container Control.app/Contents/MacOS/cctl"
        return [userBundled, appBundled].first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? NSHomeDirectory() + "/.local/bin/cctl"
    }

    public struct State: Sendable, Equatable {
        public var installed: Bool
        public var running: Bool
        /// Something other than the proxy listening on port 80.
        public var portTakenBy: String?

        public init(installed: Bool, running: Bool, portTakenBy: String? = nil) {
            self.installed = installed
            self.running = running
            self.portTakenBy = portTakenBy
        }
    }

    public func state() -> State {
        let job = (try? Shell.run("/bin/launchctl", ["print", "\(domain)/\(Self.label)"], timeout: 10)).flatMap { $0.ok ? LaunchdRunner.parse($0.stdout) : nil }
        var state = State(installed: isInstalled, running: job?.running ?? false)
        if !state.running, let result = try? Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(ProxyServer.defaultPort)", "-sTCP:LISTEN", "-Fc"], timeout: 5),
           let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("c") }) {
            state.portTakenBy = String(line.dropFirst())
        }
        return state
    }

    /// Installs (or reinstalls) the agent running `cctl` at `executable`.
    public func install(executable: String) throws {
        try paths.ensure()
        try FileManager.default.createDirectory(at: paths.launchAgentsDir, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable, "proxy", "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
            "EnvironmentVariables": ["CCTL_HOME": paths.base.path],
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(Self.label)"], timeout: 20)
        let result = try Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL.path], timeout: 20)
        guard result.ok else { throw ControlError.commandFailed("Could not start the proxy: \(result.errorText)") }
    }

    public func uninstall() throws {
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(Self.label)"], timeout: 20)
        if isInstalled { try FileManager.default.removeItem(at: plistURL) }
    }
}

extension ControlService {
    public var proxy: ProxyAgent { ProxyAgent(paths: paths) }

    /// The address to open a project at: its `.localhost` domain when the proxy is installed,
    /// otherwise `localhost:<port>`.
    public func webURL(_ project: Project) -> URL? {
        guard let port = project.port else { return nil }
        return URL(string: proxy.isInstalled ? "http://\(project.hostname ?? project.id).localhost" : "http://localhost:\(port)")
    }

    public func directURL(_ project: Project) -> URL? {
        project.port.flatMap { URL(string: "http://localhost:\($0)") }
    }
}
