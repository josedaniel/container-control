import Foundation

/// Reads and writes `projects.json`. The app, the CLI and the MCP server may all write
/// at once, so every read-modify-write runs under an exclusive `flock`.
public struct ProjectStore: Sendable {
    public let paths: Paths

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    private struct File: Codable {
        var version = 1
        var projects: [Project] = []
    }

    public func all() throws -> [Project] {
        try withLock { try load().projects }
    }

    public func get(_ id: String) throws -> Project {
        guard let project = try all().first(where: { $0.id == id }) else { throw ControlError.notFound(id) }
        return project
    }

    /// Adds a project, making its id unique. Returns the stored project.
    @discardableResult
    public func add(_ project: Project) throws -> Project {
        try withLock {
            var file = try load()
            let standardized = URL(fileURLWithPath: project.path).standardizedFileURL.path
            if let existing = file.projects.first(where: { $0.path == standardized }) {
                throw ControlError.alreadyExists("the folder is already registered as '\(existing.id)'")
            }
            var stored = project
            stored.path = standardized
            stored.id = Self.uniqueID(Slug.make(project.id.isEmpty ? project.name : project.id), taken: Set(file.projects.map(\.id)))
            file.projects.append(stored)
            try save(file)
            return stored
        }
    }

    @discardableResult
    public func update(_ id: String, _ change: (inout Project) throws -> Void) throws -> Project {
        try withLock {
            var file = try load()
            guard let index = file.projects.firstIndex(where: { $0.id == id }) else { throw ControlError.notFound(id) }
            try change(&file.projects[index])
            file.projects[index].id = id
            try save(file)
            return file.projects[index]
        }
    }

    public func remove(_ id: String) throws {
        try withLock {
            var file = try load()
            guard file.projects.contains(where: { $0.id == id }) else { throw ControlError.notFound(id) }
            file.projects.removeAll { $0.id == id }
            try save(file)
        }
    }

    static func uniqueID(_ base: String, taken: Set<String>) -> String {
        let root = base.isEmpty ? "project" : base
        var candidate = root
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(root)-\(n)"
            n += 1
        }
        return candidate
    }

    // MARK: - Disk

    private func load() throws -> File {
        guard let data = try? Data(contentsOf: paths.projectsFile), !data.isEmpty else { return File() }
        return try Self.decoder.decode(File.self, from: data)
    }

    private func save(_ file: File) throws {
        try Self.encoder.encode(file).write(to: paths.projectsFile, options: .atomic)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try paths.ensure()
        let fd = open(paths.lockFile.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw ControlError.invalid("Could not open \(paths.lockFile.path)") }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum Slug {
    public static func make(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
        var slug = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }
}
