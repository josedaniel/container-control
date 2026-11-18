import Foundation

/// A partial update to a project, as an agent or the CLI sends it. Nil fields stay as they are;
/// an empty string clears an optional text field.
public struct ProjectChanges: Codable, Sendable, Equatable {
    public var name: String?
    public var kind: ProjectKind?
    public var startCommand: String?
    public var stopCommand: String?
    /// 0 clears the port.
    public var port: Int?
    public var composeFile: String?
    /// Name under .localhost; empty string goes back to the id.
    public var hostname: String?
    /// Variables to add or change.
    public var setEnv: [String: String]?
    public var removeEnv: [String]?
    /// Path to an image to copy in as the logo.
    public var logo: String?

    public init() {}

    public var isEmpty: Bool { self == ProjectChanges() }

    /// Human-readable list of what changes, for confirmation requests and activity.
    public var summary: String {
        var parts: [String] = []
        if let name { parts.append("name “\(name)”") }
        if let kind { parts.append("kind \(kind.rawValue)") }
        if let startCommand { parts.append(startCommand.isEmpty ? "no start command" : "start command `\(startCommand)`") }
        if let stopCommand { parts.append(stopCommand.isEmpty ? "no stop command" : "stop command `\(stopCommand)`") }
        if let port { parts.append(port == 0 ? "no port" : "port \(port)") }
        if let composeFile { parts.append(composeFile.isEmpty ? "default compose file" : "compose file \(composeFile)") }
        if let hostname { parts.append(hostname.isEmpty ? "default domain" : "domain \(Hostnames.normalize(hostname)).localhost") }
        if let setEnv, !setEnv.isEmpty { parts.append("variables " + setEnv.keys.sorted().joined(separator: ", ")) }
        if let removeEnv, !removeEnv.isEmpty { parts.append("remove variables " + removeEnv.sorted().joined(separator: ", ")) }
        if logo != nil { parts.append("logo") }
        return parts.joined(separator: "; ")
    }

    /// Applies everything except the logo, which needs copying (see `ControlService.update`).
    public func apply(to project: inout Project) {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { project.name = name.trimmingCharacters(in: .whitespaces) }
        if let kind { project.kind = kind }
        if let startCommand { project.startCommand = startCommand.isEmpty ? nil : startCommand }
        if let stopCommand { project.stopCommand = stopCommand.isEmpty ? nil : stopCommand }
        if let port { project.port = port == 0 ? nil : port }
        if let composeFile { project.composeFile = composeFile.isEmpty ? nil : composeFile }
        if let hostname { project.hostname = hostname.isEmpty ? nil : Hostnames.normalize(hostname) }
        for (key, value) in setEnv ?? [:] { project.env[key] = value }
        for key in removeEnv ?? [] { project.env.removeValue(forKey: key) }
    }
}

/// Names a project can be reached at under .localhost.
public enum Hostnames {
    /// `Acme.localhost` → `acme`; `http://admin.acme.localhost/` → `admin.acme`.
    public static func normalize(_ text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["http://", "https://"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        if let slash = name.firstIndex(of: "/") { name = String(name[..<slash]) }
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        while name.hasSuffix(".") { name.removeLast() }
        if name.hasSuffix(".localhost") { name.removeLast(".localhost".count) }
        return name
    }

    /// Checks a normalized name is a valid DNS name and not taken by another project's
    /// hostname or id.
    public static func validate(_ name: String, for id: String, among projects: [Project]) throws {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        let valid = !name.isEmpty && name.count <= 200 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        }
        guard valid else {
            throw ControlError.invalid("“\(name)” is not a valid domain. Use letters, numbers and hyphens, for example “my-app” or “admin.my-app”.")
        }
        if let other = projects.first(where: { $0.id != id && ($0.hostname == name || $0.id == name) }) {
            throw ControlError.alreadyExists("\(name).localhost already belongs to “\(other.name)”")
        }
    }

    /// The names a project answers to, preferred first.
    public static func names(of project: Project) -> [String] {
        [project.hostname, project.id].compactMap { $0 }
    }

    /// The project for a host under .localhost: the longest name that is the host or a parent
    /// of it, so `api.admin.acme.localhost` goes to the project named `admin.acme`.
    public static func project(forHost host: String, in projects: [Project]) -> Project? {
        guard host.hasSuffix(".localhost") else { return nil }
        let name = String(host.dropLast(".localhost".count))
        var best: (length: Int, project: Project)?
        for project in projects {
            for candidate in names(of: project) where name == candidate || name.hasSuffix("." + candidate) {
                if candidate.count > (best?.length ?? -1) { best = (candidate.count, project) }
            }
        }
        return best?.project
    }
}
