import Foundation

/// How Container Control can make a project listen on the port it has configured.
///
/// With `.localhost` domains the port number is an internal detail, so when a project's port
/// is taken the app moves it to a free one, but only where it knows how to do that safely.
public enum PortControl: Equatable, Sendable {
    /// Node dev server: extra arguments for its start command (plus `PORT`).
    case flag([String])
    /// Compose: the variable that sets the host port.
    case variable(String)
    /// Dockerfile: the app publishes the port itself.
    case publish
    /// Only the `PORT` variable; works if the app reads it, checked after starting.
    case environment
    /// The port is fixed somewhere the app cannot change; the reason says where.
    case fixed(String)

    public var canReassign: Bool {
        if case .fixed = self { return false }
        return true
    }

    // MARK: Per project

    public static func of(_ project: Project) -> PortControl {
        guard let port = project.port else { return .fixed("it has no port set") }
        switch project.kind {
        case .dockerfile:
            return .publish
        case .compose:
            return compose(project, port: port)
        case .node, .custom:
            return node(project, port: port)
        }
    }

    static func compose(_ project: Project, port: Int) -> PortControl {
        let root = URL(fileURLWithPath: project.path)
        guard let file = project.composeFile ?? Detector.composeNames.first(where: { Detector.exists(root, $0) }),
              let yaml = Detector.read(root, file) else {
            return .fixed("the compose file was not found")
        }
        let entries = Detector.composePorts(yaml, env: Detector.dotenv(root))
        // The entry for the configured port; otherwise the one the detector would pick.
        let entry = entries.first { $0.port == port }
            ?? entries.enumerated().min { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }?.element
        if let variable = entry?.variable { return .variable(variable) }
        return .fixed("the port is hard-coded in \(file)")
    }

    static func node(_ project: Project, port: Int) -> PortControl {
        guard let command = project.startCommand else { return .fixed("it has no start command") }
        let root = URL(fileURLWithPath: project.path)
        let scripts = Detector.read(root, "package.json").flatMap(Detector.parseJSON)?["scripts"] as? [String: String] ?? [:]

        // What actually runs: the package script behind `npm run dev`, or the command itself.
        let invocation = ScriptInvocation.parse(command)
        let body = invocation.flatMap { scripts[$0.script] } ?? command
        if Detector.scriptPort(body) != nil || body.range(of: #"(--port|-p)[= ]\$"#, options: .regularExpression) != nil {
            return .fixed("its command already sets its own port")
        }

        let args: [String]
        switch frameworkBinary(body) {
        case "vite", "remix": args = ["--port", "\(port)", "--strictPort"]
        case "astro", "nuxt", "nuxi": args = ["--port", "\(port)"]
        case "next": args = ["-p", "\(port)"]
        default: return .environment
        }
        // npm needs `--` to pass arguments to the script; pnpm, yarn and bun pass them through.
        if invocation?.runner == "npm" && !command.contains(" -- ") { return .flag(["--"] + args) }
        return .flag(args)
    }

    /// First program a script runs, skipping `FOO=bar` assignments and `cross-env`.
    static func frameworkBinary(_ script: String) -> String? {
        let first = script.split(separator: "&&").first.map(String.init) ?? script
        let skipped: Set<String> = ["cross-env", "npx", "pnpm", "exec"]
        let tokens: [String] = first.split(separator: " ").map(String.init).filter { token in
            !token.contains("=") && !skipped.contains(token)
        }
        guard let binary = tokens.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        if binary == "next" { return tokens.dropFirst().first == "dev" ? "next" : nil }
        return binary
    }

    // MARK: Command

    /// The start command with port arguments appended, when the framework is known.
    public static func startCommand(for project: Project) -> String? {
        guard let command = project.startCommand else { return nil }
        if case .flag(let args) = of(project) { return command + " " + args.joined(separator: " ") }
        return command
    }

    // MARK: Free ports

    public static let range = 4100...4999

    /// A port in `range` that nothing listens on and no other project has claimed.
    static func freePort(excluding claimed: Set<Int>) -> Int? {
        range.first { !claimed.contains($0) && isFree($0) }
    }

    /// Whether a TCP port can be bound on every interface (so nothing else listens on it).
    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var off: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(UInt16(port).bigEndian)
        address.sin6_addr = in6addr_any
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
        }
    }
}

/// `npm run dev`, `pnpm dev`, `yarn run dev`, `bun run dev`, `npm start`.
struct ScriptInvocation: Equatable {
    var runner: String
    var script: String

    static func parse(_ command: String) -> ScriptInvocation? {
        let tokens = command.split(separator: " ").map(String.init)
        guard let runner = tokens.first, ["npm", "pnpm", "yarn", "bun"].contains(runner), tokens.count >= 2 else { return nil }
        if tokens[1] == "run" || tokens[1] == "run-script" {
            return tokens.count >= 3 ? ScriptInvocation(runner: runner, script: tokens[2]) : nil
        }
        if runner == "npm" && !["start", "test"].contains(tokens[1]) { return nil }
        return ScriptInvocation(runner: runner, script: tokens[1])
    }
}
