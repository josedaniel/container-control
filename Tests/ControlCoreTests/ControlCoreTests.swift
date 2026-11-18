import Foundation
import Testing
@testable import ControlCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cctl-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, _ name: String, in dir: URL) throws {
    let file = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
}

@Suite struct DetectorTests {
    @Test func nodeWithPnpmAndVite() throws {
        let dir = try tempDir()
        try write(#"{"name":"@acme/web","scripts":{"dev":"vite"},"devDependencies":{"vite":"5"}}"#, "package.json", in: dir)
        try write("", "pnpm-lock.yaml", in: dir)
        try write("x", "public/favicon.svg", in: dir)

        let project = try Detector.detect(folder: dir.path)
        #expect(project.kind == .node)
        #expect(project.name == "web")
        #expect(project.startCommand == "pnpm dev")
        #expect(project.port == 5173)
        #expect(project.logo?.hasSuffix("public/favicon.svg") == true)
    }

    @Test func portPrecedence() throws {
        let dir = try tempDir()
        try write(#"{"scripts":{"start":"next start -p 3100"},"dependencies":{"next":"15"}}"#, "package.json", in: dir)
        try write("PORT=9999\n", ".env", in: dir)
        let project = try Detector.detect(folder: dir.path)
        #expect(project.startCommand == "npm start")
        #expect(project.port == 3100)
    }

    @Test func envPortWhenScriptHasNone() throws {
        let dir = try tempDir()
        try write(#"{"scripts":{"dev":"node index.js"}}"#, "package.json", in: dir)
        try write("FOO=1\nPORT=\"8080\"\n", ".env", in: dir)
        #expect(try Detector.detect(folder: dir.path).port == 8080)
    }

    @Test func composeWinsOverPackageJson() throws {
        let dir = try tempDir()
        try write("{}", "package.json", in: dir)
        try write("services:\n  app:\n    ports:\n      - \"127.0.0.1:8081:80\"\n", "docker-compose.yml", in: dir)
        let project = try Detector.detect(folder: dir.path)
        #expect(project.kind == .compose)
        #expect(project.port == 8081)
    }

    @Test func dockerfileExpose() throws {
        let dir = try tempDir()
        try write("FROM alpine\nexpose 7000\n", "Dockerfile", in: dir)
        let project = try Detector.detect(folder: dir.path)
        #expect(project.kind == .dockerfile)
        #expect(project.port == 7000)
    }

    @Test func unknownFolderIsCustom() throws {
        let project = try Detector.detect(folder: try tempDir().path)
        #expect(project.kind == .custom)
        #expect(project.startCommand == nil)
    }
}

@Suite struct StoreTests {
    @Test func addMakesIdsUniqueAndRejectsSameFolder() throws {
        let store = ProjectStore(paths: Paths(base: try tempDir()))
        let a = try store.add(Project(id: "", name: "My Äpplication!", path: "/tmp/a", kind: .node))
        let b = try store.add(Project(id: "my-application", name: "Other", path: "/tmp/b", kind: .node))
        #expect(a.id == "my-application")
        #expect(b.id == "my-application-2")
        #expect(throws: ControlError.self) { try store.add(Project(id: "x", name: "x", path: "/tmp/a", kind: .node)) }

        try store.update(a.id) { $0.port = 3000; $0.id = "hijack" }
        #expect(try store.get(a.id).port == 3000)
        try store.remove(b.id)
        #expect(try store.all().map(\.id) == [a.id])
    }

    @Test func decodesOlderFilesWithMissingFields() throws {
        let json = #"{"version":1,"projects":[{"id":"a","name":"A","path":"/a","kind":"compose"}]}"#
        let dir = try tempDir()
        try json.write(to: dir.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
        let project = try ProjectStore(paths: Paths(base: dir)).get("a")
        #expect(project.agentPermission == .control)
        #expect(project.env.isEmpty)
    }
}

@Suite struct PermissionTests {
    let service: ControlService
    let agent = Actor(name: "Bot", isAgent: true)

    init() throws {
        var service = ControlService(paths: Paths(base: try tempDir()))
        service.isAppRunning = { false }
        self.service = service
    }

    private func add(_ permission: AgentPermission) throws -> Project {
        try service.store.add(Project(id: permission.rawValue, name: "P", path: "/tmp/\(UUID())", kind: .custom, agentPermission: permission))
    }

    @Test func agentsCannotSeeHiddenProjects() throws {
        _ = try add(.none)
        let visible = try add(.read)
        #expect(try service.projects(actor: agent).map(\.id) == [visible.id])
        #expect(throws: ControlError.notFound("none")) { try service.project("none", actor: agent) }
    }

    @Test func readAndConfirmWithoutAppBlockControl() throws {
        for permission in [AgentPermission.read, .confirm] {
            let project = try add(permission)
            #expect(throws: ControlError.self) { try service.start(project.id, actor: agent) }
            #expect(throws: ControlError.self) { try service.stop(project.id, actor: agent) }
        }
    }

    @Test func agentsCannotEditOrRemove() throws {
        let project = try add(.control)
        #expect(throws: ControlError.self) { try service.edit(project.id, actor: agent) { $0.agentPermission = .control } }
        #expect(throws: ControlError.self) { try service.remove(project.id, actor: agent) }
        #expect(throws: ControlError.self) { try service.setLogo(project.id, image: "/dev/null", actor: agent) }
    }

    @Test func agentsCanRegisterWithDefaultPermission() throws {
        let dir = try tempDir()
        try write(#"{"name":"web","scripts":{"dev":"vite"}}"#, "package.json", in: dir)
        let project = try service.add(folder: dir.path, actor: agent) {
            $0.agentPermission = .none
            $0.port = 4000
        }
        #expect(project.agentPermission == .control)
        #expect(project.port == 4000)
        #expect(service.activity().last?.isAgent == true)
    }

    @Test func failedConfigureSavesNothing() throws {
        let dir = try tempDir()
        #expect(throws: ControlError.self) {
            try service.add(folder: dir.path, actor: agent) { _ in throw ControlError.invalid("x") }
        }
        #expect(try service.store.all().isEmpty)
    }

    @Test func actorDetection() {
        #expect(Actor.detect(["CLAUDECODE": "1"]).name == "Claude Code")
        #expect(Actor.detect(["CODEX_SANDBOX": "seatbelt"]).isAgent)
        #expect(Actor.detect(["CCTL_ACTOR": "Cursor"]) == Actor(name: "Cursor", isAgent: true))
        #expect(!Actor.detect([:]).isAgent)
    }
}

@Suite struct ParserTests {
    @Test func launchctlPrintIgnoresNestedKeys() {
        let output = "gui/501/x = {\n\tstate = not running\n\tlast exit code = 3\n\tendpoints = {\n\t\tstate = running\n\t\tpid = 9\n\t}\n}\n"
        let job = LaunchdRunner.parse(output)
        #expect(!job.running)
        #expect(job.pid == nil)
        #expect(job.lastExitCode == 3)
    }

    @Test func composePsBothFormats() {
        let lines = "{\"State\":\"running\",\"ExitCode\":0}\n{\"State\":\"exited\",\"ExitCode\":1}\n"
        let array = "[{\"State\":\"running\",\"ExitCode\":0}]"
        #expect(ComposeRunner.parse(lines).map(\.state) == ["running", "exited"])
        #expect(ComposeRunner.parse(array).count == 1)
        #expect(ComposeRunner.parse("").isEmpty)
    }

    @Test func pathMergeDedupes() {
        #expect(LoginEnvironment.mergePath("/a:/b:/a", with: ["/b", "/c"]) == "/a:/b:/c")
    }
}

@Suite struct ConfirmationTests {
    let agent = Actor(name: "Bot", isAgent: true)

    /// A custom project whose stop is a harmless command, so approving runs it for real.
    private func makeService() throws -> (ControlService, Project) {
        var service = ControlService(paths: Paths(base: try tempDir()))
        service.isAppRunning = { true }
        service.confirmationTimeout = 5
        let project = try service.store.add(Project(
            id: "p", name: "P", path: try tempDir().path, kind: .custom, stopCommand: "true", agentPermission: .confirm
        ))
        return (service, project)
    }

    /// Answers the first pending request from another thread, as the app would.
    private func answer(_ service: ControlService, approve: Bool) {
        Thread.detachNewThread {
            for _ in 0..<50 {
                if let request = service.pendingRequests().first {
                    try? service.resolve(request.id, approve: approve)
                    return
                }
                usleep(100_000)
            }
        }
    }

    @Test func approvedActionRunsAndLogs() throws {
        let (service, project) = try makeService()
        answer(service, approve: true)
        _ = try service.stop(project.id, actor: agent)
        let last = try #require(service.activity().last)
        #expect(last.ok && last.actor == "Bot" && last.isAgent)
        #expect(last.message == "Approved by the person")
        #expect(service.pendingRequests().isEmpty)
    }

    @Test func deniedActionThrows() throws {
        let (service, project) = try makeService()
        answer(service, approve: false)
        #expect(throws: ControlError.self) { try service.stop(project.id, actor: agent) }
        #expect(service.activity().last?.message == "Denied by the person")
    }

    @Test func unansweredRequestExpires() throws {
        var (service, project) = try makeService()
        service.confirmationTimeout = 0.5
        #expect(throws: ControlError.self) { try service.stop(project.id, actor: agent) }
        #expect(service.pendingRequests().isEmpty)
    }

    @Test func humansSkipConfirmation() throws {
        let (service, project) = try makeService()
        _ = try service.stop(project.id, actor: Actor(name: "Terminal", isAgent: false))
        #expect(service.activity().last?.ok == true)
    }
}

@Suite struct ComposeTests {
    typealias C = ComposeRunner.Container
    let base = ProjectStatus(id: "p", state: .stopped)
    let active: Set<String> = ["web", "db"]

    @Test func parsesServiceAndOneOffLabel() {
        let output = """
        {"Service":"studio","State":"exited","ExitCode":1,"Labels":"com.docker.compose.oneoff=False,com.docker.compose.service=studio"}
        {"Service":"web","State":"running","ExitCode":0,"Labels":"com.docker.compose.oneoff=True,com.docker.compose.service=web"}
        """
        #expect(ComposeRunner.parse(output) == [
            C(service: "studio", state: "exited", exitCode: 1, oneOff: false),
            C(service: "web", state: "running", exitCode: 0, oneOff: true),
        ])
    }

    @Test func inactiveProfileLeftoverIsNotACrash() {
        // The acme case: everything is down except Drizzle Studio (profile "tools"), which exited 1.
        let status = ComposeRunner.evaluate([C(service: "studio", state: "exited", exitCode: 1)], activeServices: active, into: base)
        #expect(status.state == .stopped)
        #expect(status.detail == nil)
    }

    @Test func oneOffContainersDoNotCountAsRunningOrCrashed() {
        let containers = [C(service: "web", state: "exited", exitCode: 2, oneOff: true)]
        #expect(ComposeRunner.evaluate(containers, activeServices: active, into: base).state == .stopped)
    }

    @Test func runningLeftoverIsMentionedButProjectStaysStopped() {
        let containers = [
            C(service: "studio", state: "running", exitCode: 0),
            C(service: "web", state: "running", exitCode: 0, oneOff: true),
        ]
        let status = ComposeRunner.evaluate(containers, activeServices: active, into: base)
        #expect(status.state == .stopped)
        #expect(status.detail == "Also running outside the main stack: studio, web")
    }

    @Test func mainStackStatesStillWork() {
        let partial = ComposeRunner.evaluate(
            [C(service: "web", state: "running", exitCode: 0), C(service: "db", state: "restarting", exitCode: 1)],
            activeServices: active, into: base)
        #expect(partial.state == .running)
        #expect(partial.detail == "1/2 servicios corriendo")

        let crashed = ComposeRunner.evaluate([C(service: "db", state: "exited", exitCode: 1)], activeServices: active, into: base)
        #expect(crashed.state == .crashed)
    }

    @Test func completedInitServicesAreNotMissing() {
        let status = ComposeRunner.evaluate(
            [C(service: "web", state: "running", exitCode: 0), C(service: "migrate", state: "exited", exitCode: 0)],
            activeServices: ["web", "migrate"], into: base)
        #expect(status.state == .running)
        #expect(status.detail == nil)
    }

    @Test func unknownActiveServicesCountsEverything() {
        let status = ComposeRunner.evaluate([C(service: "studio", state: "exited", exitCode: 1)], activeServices: nil, into: base)
        #expect(status.state == .crashed)
    }

    @Test func warningsAreDroppedFromErrors() {
        let stderr = """
        time="2026-11-18T16:36:22+01:00" level=warning msg="The \\"tYU\\" variable is not set. Defaulting to a blank string."
        WARN[0000] The "X" variable is not set.
        Error response from daemon: port is already allocated
        """
        #expect(DockerErrors.describe(stderr) == "Error response from daemon: port is already allocated")
        let progress = """
         Network app_default Creating
         Container app-web-1 Started
        Error response from daemon: Bind for 0.0.0.0:4520 failed: port is already allocated
        """
        #expect(DockerErrors.describe(progress) == "Error response from daemon: Bind for 0.0.0.0:4520 failed: port is already allocated")
        // Only warnings: keep them rather than show an empty error.
        let onlyWarning = #"level=warning msg="something""#
        #expect(DockerErrors.describe(onlyWarning) == onlyWarning)
    }
}

@Suite struct ComposePortTests {
    private func port(_ yaml: String, env: [String: String] = [:]) -> Int? {
        Detector.composePort(yaml, env: env)
    }

    @Test func blockList() {
        #expect(port("services:\n  web:\n    ports:\n      - \"3000:3000\"\n") == 3000)
        #expect(port("services:\n  web:\n    ports:\n      - 127.0.0.1:8081:80\n") == 8081)
    }

    @Test func flowList() {
        #expect(port("services:\n  web:\n    image: x\n    ports: [\"4520:80\"]\n") == 4520)
        #expect(port("services:\n  web:\n    ports: [ '8080:80', \"9090:90\" ]\n") == 8080)
        #expect(port("services:\n  web:\n    ports: [5000:5000]\n") == 5000)
        #expect(port("services:\n  web:\n    ports: [\n      \"7000:70\",\n      \"7001:71\"\n    ]\n") == 7000)
    }

    @Test func longSyntax() {
        let yaml = """
        services:
          web:
            ports:
              - target: 80
                published: "8443"
                protocol: tcp
                mode: host
        """
        #expect(port(yaml) == 8443)
    }

    @Test func ipv6RangesAndProtocols() {
        #expect(port("services:\n  a:\n    ports:\n      - \"[::1]:6000:60\"\n") == 6000)
        #expect(port("services:\n  a:\n    ports:\n      - \"3000-3005:3000-3005\"\n") == 3000)
        #expect(port("services:\n  a:\n    ports:\n      - \"53:53/udp\"\n") == 53)
    }

    @Test func interpolation() {
        let yaml = "services:\n  web:\n    ports:\n      - \"${WEB_PORT:-3000}:3000\"\n"
        #expect(port(yaml) == 3000)
        #expect(port(yaml, env: ["WEB_PORT": "4100"]) == 4100)
        #expect(port("services:\n  web:\n    ports: [\"$API_PORT:80\"]\n", env: ["API_PORT": "4200"]) == 4200)
        // Unset variable without default: skip the entry instead of misreading it.
        #expect(port("services:\n  web:\n    ports:\n      - \"${NOPE}:80\"\n      - \"5050:80\"\n") == 5050)
    }

    @Test func skipsUnpublishedAndCommentedPorts() {
        // A lone container port gets a random host port; `expose` publishes nothing.
        let yaml = """
        services:
          db:
            expose: ["5432"]
            ports:
              - "5432"
              # - "1111:1111"
          web:
            ports: ["8888:80"] # main app
        """
        #expect(port(yaml) == 8888)
        #expect(port("services:\n  web:\n    image: nginx\n") == nil)
    }

    @Test func prefersTheAppOverDatabasesAndProfiles() {
        // acme-admin: db first, then server (with debugger), client, and studio behind a profile.
        let acme = """
        services:
          db:
            image: postgres
            ports:
              - "5432:5432"
          server:
            ports:
              - "8080:8080"
              - "9229:9229"
          client:
            ports:
              - "5173:5173"
          studio:
            ports:
              - "4983:4983"
            profiles: [tools]
        """
        #expect(port(acme) == 5173)
        #expect(Detector.composePorts(acme).map(\.port) == [5432, 8080, 5173, 4983])

        let apiOnly = "services:\n  redis:\n    ports: [\"6379:6379\"]\n  api:\n    ports: [\"4000:4000\"]\n"
        #expect(port(apiOnly) == 4000)
        // Only infrastructure: fall back to the first one.
        let infra = "services:\n  postgres:\n    ports:\n      - \"${POSTGRES_PORT:-5433}:5432\"\n  minio:\n    ports: [\"9000:9000\"]\n  mailpit:\n    ports: [\"8025:8025\"]\n"
        #expect(port(infra) == 5433)
    }

    @Test func detectorReadsDotenvForCompose() throws {
        let dir = try tempDirForPorts()
        try "services:\n  web:\n    ports: [\"${PORT:-3000}:3000\"]\n".write(to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try "PORT=3456\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        #expect(try Detector.detect(folder: dir.path).port == 3456)
    }

    private func tempDirForPorts() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cctl-ports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite struct PortControlTests {
    private func nodeProject(_ scripts: [String: String], command: String, port: Int = 5173) throws -> Project {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cctl-portctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: ["scripts": scripts])
        try json.write(to: dir.appendingPathComponent("package.json"))
        return Project(id: "p", name: "P", path: dir.path, kind: .node, startCommand: command, port: port)
    }

    @Test func scriptInvocations() {
        #expect(ScriptInvocation.parse("npm run dev") == ScriptInvocation(runner: "npm", script: "dev"))
        #expect(ScriptInvocation.parse("npm start") == ScriptInvocation(runner: "npm", script: "start"))
        #expect(ScriptInvocation.parse("pnpm dev") == ScriptInvocation(runner: "pnpm", script: "dev"))
        #expect(ScriptInvocation.parse("yarn run serve") == ScriptInvocation(runner: "yarn", script: "serve"))
        #expect(ScriptInvocation.parse("npm install") == nil)
        #expect(ScriptInvocation.parse("node server.js") == nil)
    }

    @Test func frameworkFlags() throws {
        let vite = try nodeProject(["dev": "vite"], command: "npm run dev", port: 4100)
        #expect(PortControl.of(vite) == .flag(["--", "--port", "4100", "--strictPort"]))
        #expect(PortControl.startCommand(for: vite) == "npm run dev -- --port 4100 --strictPort")

        let next = try nodeProject(["dev": "cross-env NODE_ENV=development next dev"], command: "pnpm dev", port: 4101)
        #expect(PortControl.of(next) == .flag(["-p", "4101"]))
        #expect(PortControl.startCommand(for: next) == "pnpm dev -p 4101")

        let astro = try nodeProject(["dev": "astro dev"], command: "bun run dev", port: 4102)
        #expect(PortControl.of(astro) == .flag(["--port", "4102"]))
    }

    @Test func fixedOrEnvironmentWhenUnknown() throws {
        #expect(PortControl.of(try nodeProject(["dev": "vite --port 3000"], command: "npm run dev")) == .fixed("its command already sets its own port"))
        #expect(PortControl.of(try nodeProject(["dev": "node server.js"], command: "npm run dev")) == .environment)
        #expect(PortControl.of(try nodeProject([:], command: "python3 -m http.server")) == .environment)
        let noPort = Project(id: "x", name: "X", path: "/tmp", kind: .node, startCommand: "vite")
        #expect(!PortControl.of(noPort).canReassign)
    }

    @Test func composeVariableOrFixed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cctl-compose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("compose.yaml")

        try "services:\n  web:\n    ports:\n      - \"${WEB_PORT:-3000}:3000\"\n".write(to: file, atomically: true, encoding: .utf8)
        var project = Project(id: "c", name: "C", path: dir.path, kind: .compose, port: 3000)
        #expect(PortControl.of(project) == .variable("WEB_PORT"))
        // Still found after the app moved it to another port.
        project.port = 4100
        #expect(PortControl.of(project) == .variable("WEB_PORT"))

        try "services:\n  web:\n    ports: [\"3000:3000\"]\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!PortControl.of(project).canReassign)
    }

    @Test func hostVariables() {
        #expect(Detector.hostVariable("- \"${WEB_PORT:-3000}:3000\"") == "WEB_PORT")
        #expect(Detector.hostVariable("- 127.0.0.1:$PORT:80") == "PORT")
        #expect(Detector.hostVariable("published: ${API_PORT}") == "API_PORT")
        #expect(Detector.hostVariable("- \"3000:${INNER}\"") == nil)
    }

    @Test func freePortSkipsClaimedAndBusy() throws {
        let first = try #require(PortControl.freePort(excluding: []))
        #expect(PortControl.range.contains(first))
        #expect(PortControl.freePort(excluding: [first]) != first)
    }
}

@Suite struct ProxyRoutingTests {
    @Test func hostHeader() {
        #expect(ProxyServer.host(in: "GET / HTTP/1.1\r\nHost: Acme-Admin.localhost:80\r\nAccept: */*") == "acme-admin.localhost")
        #expect(ProxyServer.host(in: "GET / HTTP/1.1\r\nhost: web.localhost.") == "web.localhost")
        #expect(ProxyServer.host(in: "GET / HTTP/1.1\r\nAccept: */*") == "")
    }

    @Test func projectIds() {
        #expect(ProxyServer.projectId(forHost: "acme-admin.localhost") == "acme-admin")
        #expect(ProxyServer.projectId(forHost: "api.acme-admin.localhost") == "acme-admin")
        #expect(ProxyServer.projectId(forHost: "localhost") == nil)
        #expect(ProxyServer.projectId(forHost: "example.com") == nil)
    }
}

@Suite struct HostnameTests {
    let projects = [
        Project(id: "acme-admin", name: "Acme", path: "/a", kind: .compose, hostname: "admin.acme"),
        Project(id: "shop", name: "Shop", path: "/b", kind: .node),
    ]

    @Test func normalizes() {
        #expect(Hostnames.normalize(" Acme.localhost ") == "acme")
        #expect(Hostnames.normalize("http://admin.acme.localhost:80/x") == "admin.acme")
        #expect(Hostnames.normalize("my-app.") == "my-app")
    }

    @Test func validates() throws {
        try Hostnames.validate("new", for: "x", among: projects)
        try Hostnames.validate("admin.acme", for: "acme-admin", among: projects) // its own
        #expect(throws: ControlError.self) { try Hostnames.validate("shop", for: "x", among: projects) } // another id
        #expect(throws: ControlError.self) { try Hostnames.validate("admin.acme", for: "x", among: projects) }
        for bad in ["", "-a", "a-", "a..b", "ñandú", "a_b", "with space"] {
            #expect(throws: ControlError.self) { try Hostnames.validate(bad, for: "x", among: projects) }
        }
    }

    @Test func routesByLongestName() {
        #expect(Hostnames.project(forHost: "admin.acme.localhost", in: projects)?.id == "acme-admin")
        #expect(Hostnames.project(forHost: "api.admin.acme.localhost", in: projects)?.id == "acme-admin")
        #expect(Hostnames.project(forHost: "acme-admin.localhost", in: projects)?.id == "acme-admin") // id alias
        #expect(Hostnames.project(forHost: "shop.localhost", in: projects)?.id == "shop")
        #expect(Hostnames.project(forHost: "acme.localhost", in: projects) == nil)
        #expect(Hostnames.project(forHost: "shop.example.com", in: projects) == nil)
    }
}

@Suite struct UpdateTests {
    let agent = Actor(name: "Bot", isAgent: true)

    private func service(_ permission: AgentPermission) throws -> (ControlService, Project) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cctl-update-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var service = ControlService(paths: Paths(base: base))
        service.isAppRunning = { true }
        service.confirmationTimeout = 5
        let project = try service.store.add(Project(
            id: "app", name: "App", path: folder.path, kind: .node, startCommand: "npm run dev", port: 3000,
            env: ["KEEP": "1", "OLD": "x"], agentPermission: permission))
        return (service, project)
    }

    @Test func agentWithControlUpdates() throws {
        let (service, project) = try service(.control)
        var changes = ProjectChanges()
        changes.startCommand = "pnpm dev"
        changes.port = 4000
        changes.hostname = "My-App.localhost"
        changes.setEnv = ["NEW": "2"]
        changes.removeEnv = ["OLD"]
        let updated = try service.update(project.id, changes, actor: agent)
        #expect(updated.startCommand == "pnpm dev")
        #expect(updated.port == 4000)
        #expect(updated.hostname == "my-app")
        #expect(updated.env == ["KEEP": "1", "NEW": "2"])
        #expect(updated.agentPermission == .control)
        let last = try #require(service.activity().last)
        #expect(last.action == "edit" && last.isAgent && last.message?.contains("port 4000") == true)
    }

    @Test func readOnlyAgentCannotUpdate() throws {
        let (service, project) = try service(.read)
        var changes = ProjectChanges()
        changes.name = "Other"
        #expect(throws: ControlError.self) { try service.update(project.id, changes, actor: agent) }
        #expect(try service.store.get(project.id).name == "App")
    }

    @Test func confirmedUpdateWaitsForApproval() throws {
        let (service, project) = try service(.confirm)
        Thread.detachNewThread {
            for _ in 0..<50 {
                if let request = service.pendingRequests().first {
                    #expect(request.changes?.port == 5000)
                    try? service.resolve(request.id, approve: true)
                    return
                }
                usleep(100_000)
            }
        }
        var changes = ProjectChanges()
        changes.port = 5000
        let updated = try service.update(project.id, changes, actor: agent)
        #expect(updated.port == 5000)
        #expect(service.activity().last?.message?.contains("approved by the person") == true)
    }

    @Test func invalidChangesAreRejected() throws {
        let (service, project) = try service(.control)
        var bad = ProjectChanges()
        bad.port = 70000
        #expect(throws: ControlError.self) { try service.update(project.id, bad, actor: agent) }
        var clash = ProjectChanges()
        clash.hostname = "app" // its own id is fine
        _ = try service.update(project.id, clash, actor: agent)
        #expect(try service.store.get(project.id).hostname == nil)
    }

    @Test func appEditsKeepPublishingState() throws {
        let (service, project) = try service(.control)
        try service.store.update(project.id) { $0.publicURL = "https://a-b-c.trycloudflare.com" }
        var stale = project // a draft from before publishing
        stale.name = "Renombrado"
        let saved = try service.edit(project.id, actor: .app) { $0 = stale }
        #expect(saved.name == "Renombrado")
        #expect(saved.publicURL == "https://a-b-c.trycloudflare.com")
    }

}

@Suite struct PersonApprovalTests {
    let agent = Actor(name: "Bot", isAgent: true)

    private func service(_ permission: AgentPermission = .control) throws -> (ControlService, Project) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cctl-approval-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var service = ControlService(paths: Paths(base: base))
        service.isAppRunning = { true }
        service.confirmationTimeout = 5
        let project = try service.store.add(Project(id: "app", name: "App", path: folder.path, kind: .custom, agentPermission: permission))
        return (service, project)
    }

    /// Answers the next request like the person would, recording what was asked.
    private func answer(_ service: ControlService, approve: Bool, seen: RequestBox) {
        Thread.detachNewThread {
            for _ in 0..<50 {
                if let request = service.pendingRequests().first {
                    seen.request = request
                    try? service.resolve(request.id, approve: approve)
                    return
                }
                usleep(100_000)
            }
        }
    }

    @Test func agentRemovesAfterApproval() throws {
        let (service, project) = try service(.read) // even read-only agents may ask
        let seen = RequestBox()
        answer(service, approve: true, seen: seen)
        try service.remove(project.id, actor: agent)
        #expect(seen.request?.action == "remove")
        #expect(try service.store.all().isEmpty)
        #expect(service.activity().last?.message == "Approved by the person")
    }

    @Test func agentChangesPermissionAfterApproval() throws {
        let (service, project) = try service(.control)
        let seen = RequestBox()
        answer(service, approve: true, seen: seen)
        let updated = try service.setAgentPermission(project.id, .confirm, actor: agent)
        #expect(seen.request?.value == "confirm")
        #expect(updated.agentPermission == .confirm)
    }

    @Test func deniedPublishChangesNothing() throws {
        let (service, project) = try service(.control)
        let seen = RequestBox()
        answer(service, approve: false, seen: seen)
        #expect(throws: ControlError.self) { try service.publish(project.id, actor: agent) }
        #expect(seen.request?.action == "publish")
        #expect(try service.store.get(project.id).publicURL == nil)
    }

    @Test func deniedDomainsChangeNothing() throws {
        let (service, _) = try service()
        let seen = RequestBox()
        answer(service, approve: false, seen: seen)
        #expect(throws: ControlError.self) { try service.setDomains(true, actor: agent) }
        #expect(seen.request?.projectId == ControlService.systemId && seen.request?.value == "on")
        #expect(!service.proxy.isInstalled)
    }

    @Test func hiddenProjectsCannotBeRequested() throws {
        let (service, project) = try service(.none)
        #expect(throws: ControlError.notFound("app")) { try service.remove(project.id, actor: agent) }
        #expect(service.pendingRequests().isEmpty)
    }

    @Test func peopleSkipApproval() throws {
        let (service, project) = try service(.control)
        try service.setAgentPermission(project.id, .read, actor: .app)
        #expect(try service.store.get(project.id).agentPermission == .read)
        try service.remove(project.id, actor: Actor(name: "Terminal", isAgent: false))
        #expect(try service.store.all().isEmpty)
    }
}

final class RequestBox: @unchecked Sendable {
    var request: ConfirmationRequest?
}

@Suite struct QuickTunnelTests {
    @Test func readsTheTunnelAddressFromTheLog() {
        let log = """
        2026-11-18T16:38:25Z INF Requesting new quick Tunnel on trycloudflare.com...
        2026-11-18T16:38:25Z INF see https://api.trycloudflare.com for details
        2026-11-18T16:38:30Z INF |  https://filters-moms-shades-certainly.trycloudflare.com                                    |
        """
        #expect(QuickTunnel.address(in: log) == "https://filters-moms-shades-certainly.trycloudflare.com")
        #expect(QuickTunnel.address(in: "INF Requesting new quick Tunnel on trycloudflare.com...") == nil)
    }

    @Test func forgetsAddressesOfClosedTunnels() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cctl-tunnel-\(UUID().uuidString)")
        let service = ControlService(paths: Paths(base: base))
        let project = try service.store.add(Project(id: "app", name: "App", path: "/tmp/app-\(UUID())", kind: .custom))
        try service.store.update(project.id) { $0.publicURL = "https://gone-for-good.trycloudflare.com" }
        service.syncPublished() // no cloudflared job is running for it
        #expect(try service.store.get(project.id).publicURL == nil)
        #expect(service.activity().last?.action == "unpublish")
    }
}
