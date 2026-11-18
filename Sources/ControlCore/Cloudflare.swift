import Foundation

/// Publishes a project on a throwaway `https://<random-words>.trycloudflare.com` address with a
/// Cloudflare Quick Tunnel: no account needed, a new address every time.
///
/// Each tunnel is a `cloudflared` process run by launchd (from our own folder, so it does not
/// come back at login). The address lives only as long as that process: once it exits, it is gone.
public struct QuickTunnel: Sendable {
    public let paths: Paths

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    static func label(_ id: String) -> String { "com.containercontrol.tunnel.\(id)" }
    var domain: String { "gui/\(getuid())" }
    func plistURL(_ id: String) -> URL { paths.agentsDir.appendingPathComponent("\(Self.label(id)).plist") }
    public func logFile(_ id: String) -> URL { paths.logsDir.appendingPathComponent("\(id).tunnel.log") }

    /// Path to `cloudflared`, if installed.
    public static var cli: String? {
        let found = try? Shell.tool("which", ["cloudflared"], timeout: 5)
        return found?.ok == true ? found!.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// Starts a tunnel to `target`, sending `hostHeader` as Host so dev servers that only accept
    /// local hosts (Vite) answer. Returns once the address resolves publicly and reaches us.
    public func start(_ id: String, target: String, hostHeader: String, timeout: TimeInterval = 60) throws -> String {
        guard let cli = Self.cli else {
            throw ControlError.commandFailed("cloudflared was not found. Install it with `brew install cloudflared`.")
        }
        try paths.ensure()
        stop(id)
        try? FileManager.default.removeItem(at: logFile(id))

        let plist: [String: Any] = [
            "Label": Self.label(id),
            "ProgramArguments": [cli, "tunnel", "--no-autoupdate", "--url", target, "--http-host-header", hostHeader],
            "StandardOutPath": logFile(id).path,
            "StandardErrorPath": logFile(id).path,
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL(id), options: .atomic)
        let result = try Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL(id).path], timeout: 20)
        guard result.ok else { throw ControlError.commandFailed("Could not start cloudflared: \(result.errorText)") }

        let deadline = Date().addingTimeInterval(timeout)
        var address: String?
        while Date() < deadline {
            if address == nil { address = currentURL(id) }
            // Ask Cloudflare's resolver directly: querying through the system before the name
            // exists would make macOS cache "not found" and break the link here for a while.
            if let address, let host = URL(string: address)?.host(), let ip = Self.publicIP(of: host), Self.reaches(address, via: ip) {
                // Only now ask this Mac's resolver (it may forward through Tailscale or the ISP and
                // lag behind): the name exists, so there is no "not found" to cache.
                let localDeadline = Date().addingTimeInterval(20)
                while Date() < localDeadline && !Self.resolvesLocally(host) { usleep(1_000_000) }
                return address
            }
            guard isRunning(id) else { break }
            usleep(1_000_000)
        }
        let tail = (try? String(contentsOf: logFile(id), encoding: .utf8))?.split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
        stop(id)
        throw ControlError.commandFailed("Cloudflare did not hand out the link in time. Try again.\n\(tail)")
    }

    public func stop(_ id: String) {
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(Self.label(id))"], timeout: 20)
        try? FileManager.default.removeItem(at: plistURL(id))
    }

    public func isRunning(_ id: String) -> Bool {
        guard let result = try? Shell.run("/bin/launchctl", ["print", "\(domain)/\(Self.label(id))"], timeout: 10), result.ok else { return false }
        return LaunchdRunner.parse(result.stdout).running
    }

    /// The address cloudflared printed, from its log.
    public func currentURL(_ id: String) -> String? {
        guard let log = try? String(contentsOf: logFile(id), encoding: .utf8) else { return nil }
        return Self.address(in: log)
    }

    static func address(in log: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https://[a-z0-9-]+\.trycloudflare\.com"#) else { return nil }
        let matches = regex.matches(in: log, range: NSRange(log.startIndex..., in: log))
        // cloudflared's own docs link (api.trycloudflare.com) is not a tunnel address.
        return matches.compactMap { Range($0.range, in: log).map { String(log[$0]) } }.last { !$0.hasPrefix("https://api.") }
    }

    static func publicIP(of host: String) -> String? {
        guard let result = try? Shell.run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "@1.1.1.1", host], timeout: 5), result.ok else { return nil }
        return result.stdout.split(separator: "\n").map(String.init).first { $0.first?.isNumber == true }
    }

    static func resolvesLocally(_ host: String) -> Bool {
        guard let result = try? Shell.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", host], timeout: 5) else { return false }
        return result.stdout.contains("ip_address")
    }

    /// Whether the address answers through the tunnel (any HTTP status means it is connected).
    static func reaches(_ address: String, via ip: String) -> Bool {
        guard let host = URL(string: address)?.host(),
              let result = try? Shell.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-m", "5", "-w", "%{http_code}", "--resolve", "\(host):443:\(ip)", address], timeout: 8)
        else { return false }
        let code = Int(result.stdout) ?? 0
        return code > 0 && code != 530 && code != 1033 // 530/1033: Cloudflare has no tunnel for it yet
    }
}

extension ControlService {
    public var tunnels: QuickTunnel { QuickTunnel(paths: paths) }

    /// Gives a project a public, throwaway trycloudflare.com address. Agents need approval.
    ///
    /// The tunnel goes through the .localhost proxy when it runs (Host `<name>.localhost`), so
    /// visitors see the "stopped" page instead of a Cloudflare error while the project is off;
    /// otherwise straight to the project's port with Host `localhost:<port>`.
    @discardableResult
    public func publish(_ id: String, actor: Actor, confirmed: Bool = false) throws -> Project {
        let project = try store.get(id)
        if try authorize(.publish, project, actor) == .needsConfirmation && !confirmed {
            _ = try awaitConfirmation(.publish, project, actor)
            return try store.get(id)
        }
        guard let port = project.port else { throw ControlError.invalid("\(project.name) has no port, so there is nothing to publish.") }
        if project.publicURL != nil, tunnels.isRunning(id) { return project }

        let viaProxy = proxy.state().running
        let target = viaProxy ? "http://localhost:\(ProxyServer.defaultPort)" : "http://localhost:\(port)"
        let hostHeader = viaProxy ? "\(project.hostname ?? project.id).localhost" : "localhost:\(port)"
        let url = try tunnels.start(id, target: target, hostHeader: hostHeader)
        let updated = try store.update(id) { $0.publicURL = url }
        log(id, "publish", actor, ok: true, message: url + (confirmed ? " · approved by the person" : ""))
        return updated
    }

    /// Closes the tunnel; its address stops working for good. Agents need approval.
    @discardableResult
    public func unpublish(_ id: String, actor: Actor, confirmed: Bool = false) throws -> Project {
        let project = try store.get(id)
        if try authorize(.unpublish, project, actor) == .needsConfirmation && !confirmed {
            _ = try awaitConfirmation(.unpublish, project, actor)
            return try store.get(id)
        }
        tunnels.stop(id)
        guard project.publicURL != nil else { return project }
        let updated = try store.update(id) { $0.publicURL = nil }
        log(id, "unpublish", actor, ok: true, message: project.publicURL)
        return updated
    }

    /// Forgets addresses whose tunnel is gone (cloudflared exited, the Mac restarted), since a
    /// quick tunnel's address cannot be recovered. Cheap when nothing is published.
    public func syncPublished() {
        guard let published = try? store.all().filter({ $0.publicURL != nil }), !published.isEmpty else { return }
        for project in published where !tunnels.isRunning(project.id) {
            tunnels.stop(project.id)
            _ = try? store.update(project.id) { $0.publicURL = nil }
            log(project.id, "unpublish", Actor(name: "Container Control", isAgent: false), ok: true, message: "The tunnel closed; \(project.publicURL ?? "") no longer works")
        }
    }
}
