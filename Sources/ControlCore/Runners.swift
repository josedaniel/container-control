import Foundation

/// A command to run in the foreground, used for `logs --follow`.
public struct Invocation: Sendable {
    public var executable: String
    public var arguments: [String]
    public var cwd: String?
    public var environment: [String: String]?
}

/// Starts, stops and inspects one kind of project.
protocol Runner: Sendable {
    func start(_ project: Project) throws
    func stop(_ project: Project) throws
    func status(_ project: Project) -> ProjectStatus
    func logs(_ project: Project, tail: Int, follow: Bool) -> Invocation
}

enum Ports {
    /// PIDs listening on a TCP port, via `lsof`.
    static func listeners(_ port: Int) -> [Int] {
        guard let result = try? Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeout: 5) else { return [] }
        return result.stdout.split(whereSeparator: \.isNewline).compactMap { Int($0) }
    }
}

// MARK: - launchd (node, custom)

/// Runs the start command as a launchd job so it keeps running after the app or CLI exits.
/// Plists live in our own folder, not `~/Library/LaunchAgents`, so they do not autostart at login.
struct LaunchdRunner: Runner {
    let paths: Paths

    static func label(_ id: String) -> String { "com.containercontrol.\(id)" }
    var domain: String { "gui/\(getuid())" }

    func plistURL(_ id: String) -> URL { paths.agentsDir.appendingPathComponent("\(Self.label(id)).plist") }

    func start(_ project: Project) throws {
        guard project.startCommand?.trimmingCharacters(in: .whitespaces).isEmpty == false,
              let command = PortControl.startCommand(for: project) else {
            throw ControlError.missingCommand(project.id)
        }
        try paths.ensure()
        let log = paths.logFile(for: project.id)
        rotate(log)
        appendLine(log, "\n=== \(ISO8601DateFormatter().string(from: Date())) · \(command) ===")

        var env = project.env
        env["PATH"] = LoginEnvironment.path(paths: paths)
        env["HOME"] = NSHomeDirectory()
        env["CCTL_PROJECT"] = project.id
        if let port = project.port, env["PORT"] == nil { env["PORT"] = String(port) }

        let plist: [String: Any] = [
            "Label": Self.label(project.id),
            "ProgramArguments": ["/bin/zsh", "-c", command],
            "WorkingDirectory": project.path,
            "EnvironmentVariables": env,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ExitTimeOut": 10,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL(project.id), options: .atomic)

        // A crashed job stays registered; remove it before registering again.
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(Self.label(project.id))"], timeout: 20)
        let result = try Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL(project.id).path], timeout: 20)
        guard result.ok else {
            throw ControlError.commandFailed("launchctl bootstrap failed: \(result.errorText)")
        }
    }

    func stop(_ project: Project) throws {
        if let stopCommand = project.stopCommand, !stopCommand.isEmpty {
            let result = try Shell.run("/bin/zsh", ["-c", stopCommand], cwd: project.path, environment: LoginEnvironment.environment(paths: paths), timeout: 60)
            if !result.ok { throw ControlError.commandFailed("The stop command failed: \(result.errorText)") }
        }
        guard job(project.id) != nil else { return }
        let result = try Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(Self.label(project.id))"], timeout: 30)
        if !result.ok && job(project.id) != nil {
            throw ControlError.commandFailed("launchctl bootout failed: \(result.errorText)")
        }
        // bootout returns before the process tree is gone; wait for the port to free up.
        if let port = project.port {
            for _ in 0..<40 where !Ports.listeners(port).isEmpty { usleep(250_000) }
        }
    }

    func status(_ project: Project) -> ProjectStatus {
        var status = ProjectStatus(id: project.id, state: .stopped, port: project.port)
        let listeners = project.port.map(Ports.listeners) ?? []

        guard let job = job(project.id) else {
            if let pid = listeners.first {
                status.state = .external
                status.pid = pid
                status.detail = "Port \(project.port!) is taken by a process Container Control did not start"
            }
            return status
        }

        if job.running {
            status.pid = job.pid
            status.state = (project.port == nil || !listeners.isEmpty) ? .running : .starting
        } else if let code = job.lastExitCode, code != 0 {
            status.state = .crashed
            status.detail = "Exited with code \(code). Check the logs."
        }
        return status
    }

    func logs(_ project: Project, tail: Int, follow: Bool) -> Invocation {
        var args = ["-n", String(tail)]
        if follow { args.append("-F") }
        args.append(paths.logFile(for: project.id).path)
        return Invocation(executable: "/usr/bin/tail", arguments: args)
    }

    // MARK: launchctl

    struct Job {
        var running: Bool
        var pid: Int?
        var lastExitCode: Int?
    }

    func job(_ id: String) -> Job? {
        guard let result = try? Shell.run("/bin/launchctl", ["print", "\(domain)/\(Self.label(id))"], timeout: 10), result.ok else {
            return nil
        }
        return Self.parse(result.stdout)
    }

    /// Parses the top-level keys of `launchctl print` (lines indented by one tab).
    static func parse(_ output: String) -> Job {
        var job = Job(running: false)
        for line in output.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.dropFirst().split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "state": job.running = parts[1] == "running"
            case "pid": job.pid = Int(parts[1])
            case "last exit code": job.lastExitCode = Int(parts[1])
            default: break
            }
        }
        return job
    }

    // MARK: Log files

    private func rotate(_ log: URL, maxBytes: Int = 5_000_000) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: log.path))?[.size] as? Int, size > maxBytes else { return }
        let old = log.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: log, to: old)
    }

    private func appendLine(_ log: URL, _ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }
}

// MARK: - Docker Compose

struct ComposeRunner: Runner {
    func base(_ project: Project) -> [String] {
        var args = ["compose"]
        if let file = project.composeFile { args += ["-f", file] }
        return args
    }

    /// When the host port comes from a variable (`"${WEB_PORT:-3000}:3000"`), sets it to the
    /// configured port, so the project can be moved off a port that is taken.
    func start(_ project: Project) throws {
        var environment: [String: String] = [:]
        if let port = project.port, case .variable(let name) = PortControl.of(project) { environment[name] = String(port) }
        try docker(base(project) + ["up", "-d"], project, environment: environment, timeout: 900)
    }

    /// Takes down every service, including those in profiles that are not active by default
    /// (`docker compose --profile tools up studio`) and one-off `docker compose run` containers.
    /// A plain `down` leaves those behind, and a leftover that exited with an error made the
    /// project look crashed.
    func stop(_ project: Project) throws {
        try docker(base(project) + profileArgs(project) + ["down", "--remove-orphans"], project, timeout: 180)
    }

    /// `--profile` for each profile the compose file declares. Listing them explicitly works on
    /// any Compose v2; `--profile "*"` is the fallback if they cannot be listed.
    func profileArgs(_ project: Project) -> [String] {
        guard let result = try? Shell.tool("docker", base(project) + ["config", "--profiles"], cwd: project.path, timeout: 15),
              result.ok else { return ["--profile", "*"] }
        return Self.lines(result.stdout).flatMap { ["--profile", $0] }
    }

    func status(_ project: Project) -> ProjectStatus {
        var status = ProjectStatus(id: project.id, state: .stopped, port: project.port)
        guard let result = try? Shell.tool("docker", base(project) + ["ps", "--all", "--format", "json"], cwd: project.path, timeout: 15) else {
            status.state = .unknown
            return status
        }
        guard result.ok else {
            status.state = .unknown
            status.detail = DockerErrors.describe(result.errorText)
            return status
        }
        let containers = Self.parse(result.stdout)
        guard !containers.isEmpty else { return status }
        return Self.evaluate(containers, activeServices: activeServices(project), into: status)
    }

    /// Services of the active profiles (default ones plus any set in `COMPOSE_PROFILES`).
    /// Nil when unknown, in which case every container counts.
    func activeServices(_ project: Project) -> Set<String>? {
        guard let result = try? Shell.tool("docker", base(project) + ["config", "--services"], cwd: project.path, timeout: 15),
              result.ok else { return nil }
        return Set(Self.lines(result.stdout))
    }

    /// Derives the project state from the main stack only: services in active profiles, not
    /// one-off `run` containers. Leftovers can neither crash nor turn on the project, but if
    /// they are still running, the detail says so.
    static func evaluate(_ containers: [Container], activeServices: Set<String>?, into status: ProjectStatus) -> ProjectStatus {
        var status = status
        let isMain = { (c: Container) in !c.oneOff && (activeServices?.contains(c.service) ?? true) }
        let main = containers.filter(isMain)
        let extras = containers.filter { !isMain($0) && $0.state == "running" }

        var details: [String] = []
        let running = main.filter { $0.state == "running" }.count
        // Init services (deps, migrations) exit 0 on purpose; they are not missing services.
        let expected = main.filter { !($0.state == "exited" && $0.exitCode == 0) }.count
        if running > 0 {
            status.state = .running
            if running < expected { details.append("\(running)/\(expected) servicios corriendo") }
        } else if main.contains(where: { $0.exitCode != 0 }) {
            status.state = .crashed
            details.append("The containers exited with an error. Check the logs.")
        }
        if !extras.isEmpty {
            let names = Array(Set(extras.map(\.service))).sorted().joined(separator: ", ")
            details.append("Also running outside the main stack: \(names)")
        }
        status.detail = details.isEmpty ? nil : details.joined(separator: " · ")
        return status
    }

    func logs(_ project: Project, tail: Int, follow: Bool) -> Invocation {
        var args = ["docker"] + base(project) + ["logs", "--no-color", "--tail", String(tail)]
        if follow { args.append("--follow") }
        return Invocation(executable: "/usr/bin/env", arguments: args, cwd: project.path, environment: LoginEnvironment.environment())
    }

    struct Container: Equatable {
        var service: String = ""
        var state: String
        var exitCode: Int
        /// Created by `docker compose run`.
        var oneOff: Bool = false
    }

    /// `docker compose ps --format json` prints either a JSON array or one object per line.
    static func parse(_ output: String) -> [Container] {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var objects: [[String: Any]] = []
        if text.hasPrefix("["), let array = Detector.parseJSONArray(text) {
            objects = array
        } else {
            objects = text.split(whereSeparator: \.isNewline).compactMap { Detector.parseJSON(String($0)) }
        }
        return objects.map {
            let labels = $0["Labels"] as? String ?? ""
            return Container(
                service: $0["Service"] as? String ?? "",
                state: ($0["State"] as? String ?? "").lowercased(),
                exitCode: $0["ExitCode"] as? Int ?? 0,
                oneOff: labels.contains("com.docker.compose.oneoff=True")
            )
        }
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Dockerfile

struct DockerfileRunner: Runner {
    static func container(_ id: String) -> String { "cctl-\(id)" }
    static func image(_ id: String) -> String { "cctl/\(id)" }

    func start(_ project: Project) throws {
        let name = Self.container(project.id)
        try docker(["build", "-t", Self.image(project.id), "."], project, timeout: 1800)
        _ = try? Shell.tool("docker", ["rm", "-f", name], timeout: 30)

        var args = ["run", "-d", "--name", name]
        if let port = project.port {
            // The container keeps listening where its Dockerfile says; only the host side moves.
            let container = Detector.read(URL(fileURLWithPath: project.path), "Dockerfile").flatMap(Detector.exposedPort) ?? port
            args += ["-p", "\(port):\(container)"]
        }
        if FileManager.default.fileExists(atPath: (project.path as NSString).appendingPathComponent(".env")) {
            args += ["--env-file", ".env"]
        }
        for (key, value) in project.env.sorted(by: { $0.key < $1.key }) { args += ["-e", "\(key)=\(value)"] }
        args.append(Self.image(project.id))
        try docker(args, project, timeout: 120)
    }

    func stop(_ project: Project) throws {
        let name = Self.container(project.id)
        guard inspect(name) != nil else { return }
        try docker(["rm", "-f", name], project, timeout: 60)
    }

    func status(_ project: Project) -> ProjectStatus {
        var status = ProjectStatus(id: project.id, state: .stopped, port: project.port)
        guard let state = inspect(Self.container(project.id)) else { return status }
        if state["Running"] as? Bool == true {
            status.state = .running
            status.pid = state["Pid"] as? Int
        } else if let code = state["ExitCode"] as? Int, code != 0 {
            status.state = .crashed
            status.detail = "The container exited with code \(code). Check the logs."
        }
        return status
    }

    func logs(_ project: Project, tail: Int, follow: Bool) -> Invocation {
        var args = ["docker", "logs", "--tail", String(tail)]
        if follow { args.append("--follow") }
        args.append(Self.container(project.id))
        return Invocation(executable: "/usr/bin/env", arguments: args, environment: LoginEnvironment.environment())
    }

    private func inspect(_ name: String) -> [String: Any]? {
        guard let result = try? Shell.tool("docker", ["inspect", "--format", "{{json .State}}", name], timeout: 15), result.ok else { return nil }
        return Detector.parseJSON(result.stdout)
    }
}

// MARK: - Shared Docker helpers

@discardableResult
private func docker(_ args: [String], _ project: Project, environment: [String: String] = [:], timeout: TimeInterval) throws -> ShellResult {
    let result = try Shell.tool("docker", args, cwd: project.path, environment: environment, timeout: timeout)
    guard result.ok else {
        throw ControlError.commandFailed(result.timedOut
            ? "`docker \(args.joined(separator: " "))` took too long."
            : DockerErrors.describe(result.errorText))
    }
    return result
}

enum DockerErrors {
    static func describe(_ raw: String) -> String {
        let text = withoutWarnings(raw)
        if text.contains("Cannot connect to the Docker daemon") || text.contains("docker.sock") {
            return "Docker is not running. Open OrbStack or Docker Desktop."
        }
        if text.contains("command not found") || text.contains("No such file or directory") && text.contains("docker") {
            return "The `docker` command was not found."
        }
        return text
    }

    /// Drops Compose's warning lines (`level=warning msg="The \"X\" variable is not set…"`,
    /// or `WARN[0000]` in older versions) and progress lines (` Container web-1 Started`),
    /// which bury the actual error. Keeps the original text if nothing else is left.
    static func withoutWarnings(_ text: String) -> String {
        let kept = text.split(whereSeparator: \.isNewline).filter { line in
            !line.contains("level=warning") && !line.hasPrefix("WARN[") && !isProgress(String(line))
        }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : joined
    }

    nonisolated(unsafe) private static let progress = try! NSRegularExpression(
        pattern: #"^\s*(Network|Container|Volume|Image|Service)\s+\S+\s+[A-Z][a-z]+\s*$"#)

    static func isProgress(_ line: String) -> Bool {
        progress.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}
