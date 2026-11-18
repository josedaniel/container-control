import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }

    /// Best human-readable error text for a failed command.
    public var errorText: String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}

/// Mutable box shared with pipe-reading threads.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

public enum Shell {
    /// Runs an executable and captures its output. Never reads from stdin.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let out = DataBox()
        let err = DataBox()
        let group = DispatchGroup()
        for (pipe, box) in [(outPipe, out), (errPipe, err)] {
            group.enter()
            DispatchQueue.global().async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        try process.run()

        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            group.wait()
        }
        process.waitUntilExit()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: out.data, as: UTF8.self),
            stderr: String(decoding: err.data, as: UTF8.self),
            timedOut: timedOut
        )
    }

    /// Runs a tool such as `docker` or `lsof`, resolved through the user's login PATH.
    @discardableResult
    public static func tool(
        _ name: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment extra: [String: String] = [:],
        timeout: TimeInterval = 60
    ) throws -> ShellResult {
        let environment = LoginEnvironment.environment().merging(extra) { _, new in new }
        return try run("/usr/bin/env", [name] + arguments, cwd: cwd, environment: environment, timeout: timeout)
    }
}

/// The environment the user's interactive shell would have.
///
/// GUI apps and launchd jobs start with a minimal PATH, so `node`, `pnpm` or `docker`
/// installed through nvm, Homebrew or OrbStack would not be found. We ask an interactive
/// zsh for its PATH once and cache it for an hour.
public enum LoginEnvironment {
    static let cacheTTL: TimeInterval = 3600
    static let fallbackDirs = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        "\(NSHomeDirectory())/.orbstack/bin",
    ]

    public static func path(paths: Paths = Paths(), refresh: Bool = false) -> String {
        let cache = paths.pathCacheFile
        if !refresh,
           let attrs = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < cacheTTL,
           let cached = try? String(contentsOf: cache, encoding: .utf8),
           !cached.isEmpty {
            return cached
        }

        let resolved = resolveFromShell() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let merged = mergePath(resolved, with: fallbackDirs)
        try? paths.ensure()
        try? merged.write(to: cache, atomically: true, encoding: .utf8)
        return merged
    }

    public static func environment(paths: Paths = Paths()) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path(paths: paths)
        return env
    }

    static func resolveFromShell() -> String? {
        let marker = "__CCTL_PATH__"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
        guard let result = try? Shell.run(
            shell, ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""],
            environment: [
                "HOME": NSHomeDirectory(),
                "USER": NSUserName(),
                "TERM": "dumb",
            ],
            timeout: 10
        ) else { return nil }
        let parts = result.stdout.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    static func mergePath(_ path: String, with extra: [String]) -> String {
        var seen = Set<String>()
        var dirs: [String] = []
        for dir in path.split(separator: ":").map(String.init) + extra where !dir.isEmpty && seen.insert(dir).inserted {
            dirs.append(dir)
        }
        return dirs.joined(separator: ":")
    }
}

public enum ANSI {
    nonisolated(unsafe) private static let regex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}|\r")

    /// Removes terminal colors and cursor codes.
    public static func strip(_ text: String) -> String {
        guard text.contains("\u{1B}") || text.contains("\r") else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
