import Foundation

/// Inspects a folder and proposes a project: kind, name, start command, port and logo.
public enum Detector {
    static let composeNames = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
    static let devScripts = ["dev", "start", "serve", "develop"]
    static let logoCandidates = [
        "logo.png", "icon.png", "logo.svg", "icon.svg",
        "public/logo.png", "public/icon.png", "public/apple-touch-icon.png", "public/logo.svg",
        "public/favicon.png", "public/favicon.svg", "public/favicon.ico",
        "static/logo.png", "static/favicon.png", "static/favicon.svg",
        "app/icon.png", "app/apple-icon.png", "app/icon.svg", "app/favicon.ico",
        "src/app/icon.png", "src/app/icon.svg", "src/app/favicon.ico",
        "assets/logo.png", "assets/icon.png", "src/assets/logo.png", "src/assets/logo.svg",
        "favicon.ico",
    ]
    /// Default dev-server ports by dependency, checked in order.
    static let frameworkPorts: [(String, Int)] = [
        ("next", 3000), ("nuxt", 3000), ("@remix-run/dev", 3000), ("react-scripts", 3000),
        ("astro", 4321), ("@angular/cli", 4200), ("gatsby", 8000), ("@sveltejs/kit", 5173), ("vite", 5173),
    ]

    public static func detect(folder: String) throws -> Project {
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ControlError.invalid("The folder does not exist: \(root.path)")
        }

        let folderName = root.lastPathComponent
        var project = Project(id: Slug.make(folderName), name: folderName, path: root.path, kind: .custom)
        project.logo = findLogo(in: root)

        if let compose = composeNames.first(where: { exists(root, $0) }) {
            project.kind = .compose
            project.port = read(root, compose).flatMap { composePort($0, env: dotenv(root)) }
            return project
        }

        if let package = read(root, "package.json").flatMap(parseJSON) {
            project.kind = .node
            if let name = package["name"] as? String, !name.isEmpty {
                project.name = name.split(separator: "/").last.map(String.init) ?? name
            }
            let scripts = package["scripts"] as? [String: String] ?? [:]
            if let script = devScripts.first(where: { scripts[$0] != nil }) {
                project.startCommand = runCommand(packageManager(root), script: script)
                project.port = scriptPort(scripts[script] ?? "")
            }
            project.port = project.port ?? envPort(root) ?? frameworkPort(package)
            return project
        }

        if exists(root, "Dockerfile") {
            project.kind = .dockerfile
            project.port = read(root, "Dockerfile").flatMap(exposedPort)
            return project
        }

        project.port = envPort(root)
        return project
    }

    // MARK: - Node

    static func packageManager(_ root: URL) -> String {
        if exists(root, "pnpm-lock.yaml") { return "pnpm" }
        if exists(root, "bun.lockb") || exists(root, "bun.lock") { return "bun" }
        if exists(root, "yarn.lock") { return "yarn" }
        return "npm"
    }

    static func runCommand(_ manager: String, script: String) -> String {
        switch manager {
        case "npm": script == "start" ? "npm start" : "npm run \(script)"
        case "bun": "bun run \(script)"
        default: "\(manager) \(script)"
        }
    }

    static func scriptPort(_ script: String) -> Int? {
        firstInt(in: script, pattern: #"(?:--port[= ]|-p\s+|PORT=)(\d{2,5})"#)
    }

    static func envPort(_ root: URL) -> Int? {
        for name in [".env.local", ".env.development", ".env"] {
            if let text = read(root, name), let port = firstInt(in: text, pattern: #"(?m)^\s*PORT\s*=\s*["']?(\d{2,5})"#) {
                return port
            }
        }
        return nil
    }

    static func frameworkPort(_ package: [String: Any]) -> Int? {
        let deps = (package["dependencies"] as? [String: Any] ?? [:])
            .merging(package["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
        return frameworkPorts.first { deps[$0.0] != nil }?.1
    }

    // MARK: - Docker

    /// The host port most likely to be the app: published ports of every service, in any of
    /// Compose's syntaxes (block lists, flow lists like `ports: ["4520:80"]`, long form with
    /// `published:`), ranked so a web client beats an API, an API beats a database, and services
    /// behind a profile come last. `${VAR}` / `${VAR:-default}` resolve from `env` (the .env).
    static func composePort(_ yaml: String, env: [String: String] = [:]) -> Int? {
        composePorts(yaml, env: env)
            .enumerated()
            .min { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }?
            .element.port
    }

    struct PublishedPort: Equatable {
        var service: String
        var port: Int
        var inProfile: Bool
        /// Variable that sets the host port (`"${WEB_PORT:-3000}:3000"` → `WEB_PORT`), if any.
        var variable: String? = nil

        static let frontend = ["client", "web", "frontend", "front", "app", "ui", "site", "www", "next", "nuxt", "vite", "astro", "remix", "storybook"]
        static let backend = ["server", "api", "backend", "back", "gateway", "proxy", "nginx", "caddy", "traefik"]
        static let infrastructure = ["db", "database", "postgres", "pg", "mysql", "mariadb", "mongo", "redis", "valkey", "memcached",
                                     "rabbit", "kafka", "zookeeper", "nats", "elastic", "opensearch", "minio", "s3", "mail", "smtp",
                                     "adminer", "pgadmin", "localstack", "studio", "cache", "queue", "worker"]
        static let infrastructurePorts: Set<Int> = [5432, 5433, 3306, 27017, 6379, 11211, 5672, 15672, 9092, 2181, 4222, 9200, 9300, 1025]

        /// Lower is better.
        var rank: Int {
            let name = service.lowercased()
            let words = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            // Short tokens ("db", "pg", "s3") must be whole words; longer ones may be part of
            // the name ("mailpit", "postgres-primary", "rediscache").
            let isInfrastructure = Self.infrastructure.contains { $0.count >= 4 ? name.contains($0) : words.contains($0) }
            var rank: Int
            if isInfrastructure || Self.infrastructurePorts.contains(port) {
                rank = 3
            } else if !words.isDisjoint(with: Self.frontend) {
                rank = 0
            } else if !words.isDisjoint(with: Self.backend) {
                rank = 1
            } else {
                rank = 2
            }
            if inProfile { rank += 4 }
            return rank
        }
    }

    /// Every published host port in a compose file, in file order.
    static func composePorts(_ yaml: String, env: [String: String] = [:]) -> [PublishedPort] {
        let lines = yaml.components(separatedBy: .newlines).map(stripComment)
        let indentOf = { (line: String) in line.prefix { $0 == " " }.count }
        var result: [PublishedPort] = []
        var serviceIndent: Int?
        var service = ""
        var profiled: Set<String> = []
        var inServices = false
        var i = 0

        while i < lines.count {
            let line = lines[i]
            i += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let indent = indentOf(line)

            // Track which service we are in: keys one level under the top-level `services:`.
            if indent == 0 {
                inServices = line.hasPrefix("services:")
                serviceIndent = nil
                continue
            }
            guard inServices else { continue }
            if serviceIndent == nil { serviceIndent = indent }
            if indent == serviceIndent, let colon = line.firstIndex(of: ":") {
                service = line[..<colon].trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.range(of: #"^\s*profiles\s*:"#, options: .regularExpression) != nil {
                profiled.insert(service)
                continue
            }

            guard let key = line.range(of: #"^\s*ports\s*:"#, options: .regularExpression) else { continue }
            let rest = line[key.upperBound...].trimmingCharacters(in: .whitespaces)
            var entries: [String] = []
            if rest.hasPrefix("[") {
                // Flow list, possibly spanning several lines until the closing bracket.
                var flow = String(rest.dropFirst())
                while !flow.contains("]") && i < lines.count {
                    flow += "," + lines[i]
                    i += 1
                }
                entries = flow.prefix { $0 != "]" }.split(separator: ",").map(String.init)
            } else {
                // Block list: the lines indented deeper than `ports:`.
                while i < lines.count {
                    let next = lines[i]
                    if next.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
                    if indentOf(next) <= indent { break }
                    entries.append(next)
                    i += 1
                }
            }
            for entry in entries {
                guard let port = publishedPort(entry, env: env), port != 9229 else { continue } // 9229: Node debugger
                result.append(PublishedPort(service: service, port: port, inProfile: false, variable: hostVariable(entry)))
            }
        }
        // `profiles:` may come after `ports:` within a service, so mark them at the end.
        return result.map { var p = $0; p.inProfile = profiled.contains($0.service); return p }
    }

    /// The variable at the start of an entry's host port, before interpolation:
    /// `- "${WEB_PORT:-3000}:3000"`, `127.0.0.1:$PORT:80` or `published: ${PORT}`.
    static func hostVariable(_ entry: String) -> String? {
        let pattern = #"^\s*-?\s*(?:published\s*:\s*)?["']?(?:\d+\.\d+\.\d+\.\d+:|\[[^\]]*\]:)?\$\{?([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: entry, range: NSRange(entry.startIndex..., in: entry)),
              let range = Range(match.range(at: 1), in: entry) else { return nil }
        return String(entry[range])
    }

    /// Host port of one `ports` entry (or one line of a long-form entry), if it publishes one.
    static func publishedPort(_ entry: String, env: [String: String]) -> Int? {
        var text = entry.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("-") { text = text.dropFirst().trimmingCharacters(in: .whitespaces) }

        // Long syntax: `published: 8080` (other keys such as `target:` publish nothing).
        if let colon = text.firstIndex(of: ":"), text[..<colon].allSatisfy({ $0.isLetter || $0 == "_" }), !text[..<colon].isEmpty {
            guard text[..<colon] == "published" else { return nil }
            return firstPort(unquote(String(text[text.index(after: colon)...]), env: env))
        }

        // Short syntax: [HOST_IP:]HOST:CONTAINER[/PROTOCOL]. A lone CONTAINER port gets a
        // random host port, so there is nothing to detect.
        var spec = unquote(text, env: env)
        if let slash = spec.firstIndex(of: "/") { spec = String(spec[..<slash]) }
        if spec.hasPrefix("["), let close = spec.firstIndex(of: "]") { // IPv6 host IP
            spec = String(spec[spec.index(after: close)...]).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        }
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return firstPort(String(parts[parts.count - 2]))
    }

    /// Strips quotes and resolves `${VAR}`, `${VAR:-default}` and `$VAR`. Unresolvable variables
    /// become empty, so the entry is skipped rather than misread.
    static func unquote(_ value: String, env: [String: String]) -> String {
        var text = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let regex = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)
        while let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text) {
            let name = Range(match.range(at: 1), in: text).map { String(text[$0]) }
                ?? Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            let fallback = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            let value = env[name].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            text.replaceSubrange(whole, with: value)
        }
        return text
    }

    /// The first number of "8080" or of a range like "3000-3005".
    static func firstPort(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        guard let port = Int(digits), (1...65535).contains(port) else { return nil }
        return port
    }

    static func stripComment(_ line: String) -> String {
        // A `#` starts a comment at the start of the line or after whitespace (not inside "a#b").
        guard let range = line.range(of: #"(^|\s)#"#, options: .regularExpression) else { return line }
        return String(line[..<range.lowerBound])
    }

    /// Variables from the project's `.env`, which Compose uses for interpolation.
    static func dotenv(_ root: URL) -> [String: String] {
        guard let text = read(root, ".env") else { return [:] }
        var env: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
            env[key] = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return env
    }

    static func exposedPort(_ dockerfile: String) -> Int? {
        firstInt(in: dockerfile, pattern: #"(?mi)^\s*EXPOSE\s+(\d{2,5})"#)
    }

    // MARK: - Helpers

    static func findLogo(in root: URL) -> String? {
        logoCandidates.first { exists(root, $0) }.map { root.appendingPathComponent($0).path }
    }

    static func exists(_ root: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    static func read(_ root: URL, _ name: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    static func parseJSON(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func parseJSONArray(_ text: String) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]]
    }

    static func firstInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}
