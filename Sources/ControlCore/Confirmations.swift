import Foundation

/// An agent's request to control a project whose permission is `confirm`.
///
/// The agent's process writes it to `requests/<id>.json` and waits. The app shows it, and when
/// the person approves, the app itself runs the action and records the outcome in the file.
public struct ConfirmationRequest: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable {
        case pending
        /// Approved; the app is running the action.
        case approved
        case denied
        case expired
        case done
        case failed
    }

    public var id: String
    public var projectId: String
    public var action: String
    public var actor: String
    public var createdAt: Date
    public var expiresAt: Date
    public var status: Status
    public var message: String?
    /// For `edit` requests: what the agent wants to change.
    public var changes: ProjectChanges?
    /// For `permission` (the new level) and `domains` ("on" / "off") requests.
    public var value: String?

    public var isOpen: Bool { status == .pending && expiresAt > Date() }
}

extension ControlService {
    // MARK: Agent side

    func awaitConfirmation(_ action: Action, _ project: Project, _ actor: Actor, changes: ProjectChanges? = nil, value: String? = nil) throws -> ProjectStatus {
        guard isAppRunning() else {
            let what = project.id == Self.systemId ? "This" : "'\(project.id)'"
            let message = "\(what) needs the person to approve it in Container Control, but the app is not open."
            log(project.id, action.rawValue, actor, ok: false, message: message)
            throw ControlError.permissionDenied(message)
        }

        try paths.ensure()
        let now = Date()
        var request = ConfirmationRequest(
            id: UUID().uuidString.lowercased(), projectId: project.id, action: action.rawValue, actor: actor.name,
            createdAt: now, expiresAt: now.addingTimeInterval(confirmationTimeout), status: .pending, changes: changes, value: value
        )
        try save(request)
        defer { cleanUpRequests() }

        while true {
            usleep(300_000)
            guard let current = loadRequest(request.id) else {
                throw ControlError.commandFailed("The confirmation request disappeared.")
            }
            switch current.status {
            case .pending:
                if Date() > request.expiresAt {
                    request.status = .expired
                    try? save(request)
                    let message = "Nobody approved the request in time."
                    log(project.id, action.rawValue, actor, ok: false, message: message)
                    throw ControlError.permissionDenied("\(message) Ask the person to approve it in Container Control and try again.")
                }
            case .approved:
                continue
            case .done:
                return project.id == Self.systemId || action == .remove ? ProjectStatus(id: project.id, state: .stopped) : status(project)
            case .denied:
                throw ControlError.permissionDenied("The person denied the request to \(action.verb) '\(project.id)'.")
            case .failed:
                throw ControlError.commandFailed(current.message ?? "The action failed.")
            case .expired:
                throw ControlError.permissionDenied("The request expired.")
            }
        }
    }

    // MARK: App side

    public func pendingRequests() -> [ConfirmationRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.requestsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { loadRequest($0.deletingPathExtension().lastPathComponent) }
            .filter(\.isOpen)
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Approves or denies a request. On approval the action runs here, in the caller's process.
    public func resolve(_ requestId: String, approve: Bool) throws {
        guard var request = loadRequest(requestId), request.isOpen else {
            throw ControlError.invalid("The request is no longer pending.")
        }
        let agent = Actor(name: request.actor, isAgent: true)
        guard approve else {
            request.status = .denied
            try save(request)
            log(request.projectId, request.action, agent, ok: false, message: "Denied by the person")
            return
        }
        guard let action = Action(rawValue: request.action) else { throw ControlError.invalid("Unknown action: \(request.action)") }

        request.status = .approved
        try save(request)
        do {
            switch action {
            case .edit:
                try update(request.projectId, request.changes ?? ProjectChanges(), actor: agent, confirmed: true)
            case .remove:
                try remove(request.projectId, actor: agent, confirmed: true)
            case .publish:
                try publish(request.projectId, actor: agent, confirmed: true)
            case .unpublish:
                try unpublish(request.projectId, actor: agent, confirmed: true)
            case .permission:
                guard let level = request.value.flatMap(AgentPermission.init(rawValue:)) else { throw ControlError.invalid("Invalid permission.") }
                try setAgentPermission(request.projectId, level, actor: agent, confirmed: true)
            case .domains:
                try setDomains(request.value == "on", actor: agent, confirmed: true)
            case .start, .stop, .restart, .read:
                _ = try execute(action, request.projectId, agent, confirmed: true)
            }
            request.status = .done
        } catch {
            request.status = .failed
            request.message = error.localizedDescription
        }
        try save(request)
    }

    // MARK: Files

    private func requestURL(_ id: String) -> URL { paths.requestsDir.appendingPathComponent("\(id).json") }

    private func save(_ request: ConfirmationRequest) throws {
        try ProjectStore.encoder.encode(request).write(to: requestURL(request.id), options: .atomic)
    }

    private func loadRequest(_ id: String) -> ConfirmationRequest? {
        guard let data = try? Data(contentsOf: requestURL(id)) else { return nil }
        return try? ProjectStore.decoder.decode(ConfirmationRequest.self, from: data)
    }

    /// Deletes requests older than an hour.
    private func cleanUpRequests() {
        let cutoff = Date().addingTimeInterval(-3600)
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.requestsDir, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            if let request = loadRequest(file.deletingPathExtension().lastPathComponent), request.createdAt > cutoff { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension Action {
    /// Infinitive for messages, e.g. "start".
    public var verb: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        case .restart: "restart"
        case .read: "view"
        case .edit: "edit"
        case .remove: "remove"
        case .publish: "publish to the internet"
        case .unpublish: "unpublish"
        case .permission: "change the agent permission of"
        case .domains: "change the .localhost domains"
        }
    }
}
