import Foundation

public enum ProjectKind: String, Codable, Sendable, CaseIterable {
    /// Node project run as a launchd job (`npm run dev`, etc.).
    case node
    /// Docker Compose project (`docker compose up -d` / `down`).
    case compose
    /// Single Dockerfile, built and run as one container.
    case dockerfile
    /// Any shell command, run as a launchd job.
    case custom

    /// Kinds whose process is supervised by launchd.
    public var usesLaunchd: Bool { self == .node || self == .custom }
}

/// What an AI agent may do with a project through `cctl` or MCP.
public enum AgentPermission: String, Codable, Sendable, CaseIterable {
    case none
    case read
    case control
    case confirm
}

public struct Project: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var kind: ProjectKind
    /// Shell command for node/custom projects.
    public var startCommand: String?
    /// Optional explicit stop command for custom projects; otherwise launchd stops the job.
    public var stopCommand: String?
    public var port: Int?
    /// Absolute path to the logo image.
    public var logo: String?
    /// Compose file relative to `path`, when it is not one of the default names.
    public var composeFile: String?
    public var env: [String: String]
    /// Custom name under .localhost (`acme` → http://acme.localhost). The id always works too.
    public var hostname: String?
    /// Public address while published, e.g. https://some-random-words.trycloudflare.com
    public var publicURL: String?
    public var agentPermission: AgentPermission
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        path: String,
        kind: ProjectKind,
        startCommand: String? = nil,
        stopCommand: String? = nil,
        port: Int? = nil,
        logo: String? = nil,
        composeFile: String? = nil,
        env: [String: String] = [:],
        agentPermission: AgentPermission = .control,
        createdAt: Date = Date(),
        hostname: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.startCommand = startCommand
        self.stopCommand = stopCommand
        self.port = port
        self.logo = logo
        self.composeFile = composeFile
        self.env = env
        self.agentPermission = agentPermission
        self.createdAt = createdAt
        self.hostname = hostname
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decode(ProjectKind.self, forKey: .kind)
        startCommand = try c.decodeIfPresent(String.self, forKey: .startCommand)
        stopCommand = try c.decodeIfPresent(String.self, forKey: .stopCommand)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        composeFile = try c.decodeIfPresent(String.self, forKey: .composeFile)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
        publicURL = try c.decodeIfPresent(String.self, forKey: .publicURL)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        agentPermission = try c.decodeIfPresent(AgentPermission.self, forKey: .agentPermission) ?? .control
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public enum RunState: String, Codable, Sendable {
    case running
    /// Process is up but its port is not listening yet.
    case starting
    case stopped
    /// Process exited with an error and is still registered.
    case crashed
    /// Port is in use by a process this app did not start.
    case external
    case unknown
}

public struct ProjectStatus: Codable, Sendable, Equatable {
    public var id: String
    public var state: RunState
    public var pid: Int?
    public var port: Int?
    public var detail: String?

    public init(id: String, state: RunState, pid: Int? = nil, port: Int? = nil, detail: String? = nil) {
        self.id = id
        self.state = state
        self.pid = pid
        self.port = port
        self.detail = detail
    }

    public var isActive: Bool { state == .running || state == .starting }
}

public enum ControlError: LocalizedError, Equatable {
    case notFound(String)
    case alreadyExists(String)
    case missingCommand(String)
    case commandFailed(String)
    case permissionDenied(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "There is no project with id '\(id)'."
        case .alreadyExists(let what): "Already exists: \(what)."
        case .missingCommand(let id): "Project '\(id)' has no start command. Use `cctl set \(id) --start \"...\"`."
        case .commandFailed(let message): message
        case .permissionDenied(let message): message
        case .invalid(let message): message
        }
    }
}
