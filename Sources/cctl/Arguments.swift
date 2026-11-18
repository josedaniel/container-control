import Foundation

/// Minimal parser: positionals, `--flag`, `--key value`, `--key=value`. Repeated keys accumulate.
struct Arguments {
    static let flags: Set<String> = ["json", "follow", "f", "help", "h", "refresh"]
    static let aliases = ["f": "follow", "n": "tail", "h": "help"]

    var positionals: [String] = []
    var options: [String: [String]] = [:]

    init(_ raw: [String]) throws {
        var i = 0
        while i < raw.count {
            let arg = raw[i]
            i += 1
            guard arg.hasPrefix("-"), arg.count > 1, Int(arg) == nil else {
                positionals.append(arg)
                continue
            }
            var key = String(arg.drop(while: { $0 == "-" }))
            var value: String?
            if let eq = key.firstIndex(of: "=") {
                value = String(key[key.index(after: eq)...])
                key = String(key[..<eq])
            }
            let isFlag = Self.flags.contains(key)
            key = Self.aliases[key] ?? key
            if isFlag {
                options[key, default: []].append("true")
                continue
            }
            if value == nil {
                guard i < raw.count else { throw CLIError.usage("Missing value for --\(key)") }
                value = raw[i]
                i += 1
            }
            options[key, default: []].append(value!)
        }
    }

    func flag(_ key: String) -> Bool { options[key] != nil }
    func value(_ key: String) -> String? { options[key]?.last }
    func values(_ key: String) -> [String] { options[key] ?? [] }

    func int(_ key: String) throws -> Int? {
        guard let raw = value(key) else { return nil }
        guard let n = Int(raw) else { throw CLIError.usage("--\(key) must be a number") }
        return n
    }

    func positional(_ index: Int, _ name: String) throws -> String {
        guard index < positionals.count else { throw CLIError.usage("Missing <\(name)>") }
        return positionals[index]
    }
}

enum CLIError: LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): message
        }
    }
}
