import Foundation

/// Locations of everything Container Control stores on disk.
///
/// Defaults to `~/.config/container-control`; `CCTL_HOME` overrides it (used by tests).
public struct Paths: Sendable {
    public let base: URL

    public init(base: URL? = nil) {
        if let base {
            self.base = base
        } else if let custom = ProcessInfo.processInfo.environment["CCTL_HOME"], !custom.isEmpty {
            self.base = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            self.base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/container-control")
        }
    }

    public var projectsFile: URL { base.appendingPathComponent("projects.json") }
    public var activityFile: URL { base.appendingPathComponent("activity.jsonl") }
    public var lockFile: URL { base.appendingPathComponent(".lock") }
    public var pathCacheFile: URL { base.appendingPathComponent(".login-path") }
    public var logsDir: URL { base.appendingPathComponent("logs") }
    public var agentsDir: URL { base.appendingPathComponent("launchd") }
    public var logosDir: URL { base.appendingPathComponent("logos") }
    public var requestsDir: URL { base.appendingPathComponent("requests") }

    /// Where login-time launchd agents live. Under a custom `CCTL_HOME` it stays inside it,
    /// so isolated setups (tests, development) never touch the real one.
    public var launchAgentsDir: URL {
        base.path.hasSuffix(".config/container-control")
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
            : base.appendingPathComponent("LaunchAgents")
    }

    public func logFile(for id: String) -> URL { logsDir.appendingPathComponent("\(id).log") }

    public func ensure() throws {
        let fm = FileManager.default
        for dir in [base, logsDir, agentsDir, logosDir, requestsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
