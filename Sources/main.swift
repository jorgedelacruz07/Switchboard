import AppKit
import Darwin

func selfTest() throws {
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }
    let projects = try Controller.parseCatalog("alpha\tFolder With Spaces\t3001\t5173\nbeta\tOther\t\t5174\n")
    try check(projects.count == 2 && projects[1].ports == [5174], "Catalog with optional API and spaces")
    let resume = try Controller.parseCatalog("jorgedelacruz-resume\tjorgedelacruz-resume\t\t\n")[0]
    try check(resume.ports.isEmpty && resume.webPort == 0 && resume.webURL == nil, "Portless background project catalog")
    do { _ = try Controller.parseCatalog("broken"); throw CocoaError(.validationMissingMandatoryProperty) }
    catch let error as NSError { try check(error.domain == "Switchboard", "Reject malformed catalog") }
    let ports = Controller.listeningPorts("p123\nn127.0.0.1:3001\nn*:5173\nn[::1]:5174\n")
    try check(ports == [3001, 5173, 5174], "IPv4, IPv6 and wildcard listeners")
    try check(Controller.state(project: projects[0], listening: ports, launcherAlive: true).state == .on, "Running")
    try check(Controller.state(project: projects[0], listening: [3001], launcherAlive: true).state == .partial, "Partial")
    try check(Controller.state(project: projects[0], listening: [], launcherAlive: true).state == .partial, "Launcher without ports")
    try check(Controller.state(project: projects[0], listening: [], launcherAlive: false).state == .off, "Stopped")
    try check(Controller.state(project: resume, listening: [], launcherAlive: true).state == .on, "Portless project follows its live launcher process")
    try check(Controller.state(project: resume, listening: [], launcherAlive: false).state == .off, "Portless project stops when its launcher exits")
    try check(projects[0].webURL?.absoluteString == "http://localhost:5173" && projects[1].webURL?.absoluteString == "http://localhost:5174", "Web URL uses the catalog web port")
    let registry = FileManager.default.temporaryDirectory.appendingPathComponent("Switchboard Registry \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: registry) }
    let registryJSON = "{\"projects\":[{\"id\":\"a\",\"name\":\"Alpha\",\"kind\":\"product\",\"projectRoot\":\"$HOME/Projects/Folder With Spaces\",\"ports\":\"Client :5173\"},{\"id\":\"d\",\"name\":\"Docs\",\"kind\":\"system\",\"projectRoot\":\"$HOME/Projects/Docs\",\"ports\":\"Portal :5190\"},{\"id\":\"o\",\"name\":\"Old\",\"kind\":\"archive\",\"projectRoot\":\"$HOME/Projects/Old\",\"ports\":\"API :8000\"},{\"id\":\"c\",\"name\":\"Cli\",\"kind\":\"system\",\"projectRoot\":\"$HOME/Projects/Cli\",\"ports\":\"No port\"}]}"
    try registryJSON.write(to: registry.appendingPathComponent("workspace.registry.json"), atomically: true, encoding: .utf8)
    let extra = Controller.registryServices(root: registry, excluding: projects)
    try check(extra.count == 3 && extra[0].name == "Docs" && extra[0].webPort == 5190 && !extra[0].launcherManaged, "Registry adds unknown services with a port")
    try check(extra[1].name == "Cli" && extra[1].webPort == 0 && !extra[1].launcherManaged, "Registry adds portless tools and repositories")
    try check(extra[2].name == "Old" && extra[2].archived && Controller.state(project: extra[2], listening: [8000], launcherAlive: true).state == .archived && extra[2].portLabel == "", "Archived registry projects are listed last, portless and never running")
    try check(Controller.arguments(action: "start", key: extra[0].key, projects: projects + extra) == nil, "Registry services are not launcher-controlled")
    let docs = Project(key: "registry-projectsdocs", directory: "ProjectsDocs", ports: [5190], webPort: 5190, launcherManaged: false)
    try check(docs.isDocsPortal && !extra[0].isDocsPortal && !extra[1].isDocsPortal && !extra[2].isDocsPortal, "Only the active ProjectsDocs service gets portal controls")
    for action in ["start", "stop", "restart", "sync-push", "sync-pull"] {
        try check(Controller.arguments(action: action, key: docs.key, projects: projects + [docs]) == nil, "Portal cannot use generic launcher actions")
    }
    try check(Controller.portalURL(root: registry) == nil, "Missing private configuration stays unavailable")
    let configDirectory = registry.appendingPathComponent("ProjectsDocs")
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    let configFile = configDirectory.appendingPathComponent("docs.config.json")
    for origin in ["https://mini.example.test/", "https://mini.example.test:443/old?query=1#anchor"] {
        let data = try JSONSerialization.data(withJSONObject: ["ideaDeskUrl": origin])
        try data.write(to: configFile)
        let url = Controller.portalURL(root: registry)
        try check((url?.absoluteString == "https://mini.example.test/docs/" || url?.absoluteString == "https://mini.example.test:443/docs/") && url?.query == nil && url?.fragment == nil, "Private origin opens the docs route without root, query or fragment")
    }
    for origin in ["http://mini.example.test/", "https://mini.example.test:8443/", "https://name:secret@mini.example.test/", "/relative"] {
        let data = try JSONSerialization.data(withJSONObject: ["ideaDeskUrl": origin])
        try data.write(to: configFile)
        try check(Controller.portalURL(root: registry) == nil, "Reject non-private or credential-bearing origins")
    }
    let hostStart = Controller.portalStartCommand(role: .host)
    let clientStart = Controller.portalStartCommand(role: .client)
    let start = "launchctl kickstart \"gui/$(id -u)/com.jorgedelacruz.projects-docs\""
    try check(hostStart.executable == "/bin/bash" && hostStart.arguments == ["-c", start], "Host starts only the existing private LaunchAgent without forcing a restart")
    try check(clientStart.executable == "/usr/bin/ssh" && clientStart.arguments == ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "macmini", start], "Client starts the private LaunchAgent via noninteractive SSH without sync or publication")
    let ideaDesk = try Controller.parseCatalog("ideadesk\tIdeaDesk\t5180\t5176\n")[0]
    try check(ideaDesk.isIdeaDesk && !ideaDesk.launcherManaged && ideaDesk.ports == [5180] && ideaDesk.webPort == 5180, "IdeaDesk uses the service port and is excluded from generic Work/Sync")
    try check(Controller.state(project: ideaDesk, listening: [5180], launcherAlive: false).state == .on, "IdeaDesk needs only its LaunchAgent port, no Vite or sync PID")
    for action in ["start", "stop", "restart", "sync-push", "sync-pull"] {
        try check(Controller.arguments(action: action, key: ideaDesk.key, projects: [ideaDesk]) == nil, "IdeaDesk rejects generic launcher actions")
    }
    do { _ = try Controller.parseCatalog("ideadesk\tIdeaDesk\t\t5176\n"); throw CocoaError(.validationMissingMandatoryProperty) }
    catch let error as NSError { try check(error.domain == "Switchboard", "IdeaDesk fails closed without a catalog service port") }
    try JSONSerialization.data(withJSONObject: ["ideaDeskUrl": "https://mini.example.test/old?query=1#anchor"]).write(to: configFile)
    try check(Controller.ideaDeskURL(root: registry)?.absoluteString == "https://mini.example.test/", "IdeaDesk opens the private app root without docs, query or fragment")
    let ideaHost = Controller.ideaDeskStartCommand(role: .host)
    let ideaClient = Controller.ideaDeskStartCommand(role: .client)
    let ideaScript = ideaHost.arguments[1]
    try check(ideaHost.executable == "/bin/bash" && ideaHost.arguments[0] == "-c", "Host starts IdeaDesk through its service command")
    try check(ideaClient.executable == "/usr/bin/ssh" && ideaClient.arguments == ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "macmini", ideaScript], "Client uses the same fixed command over noninteractive SSH")
    try check(!ideaScript.contains("-k") && !ideaScript.contains("npm") && !ideaScript.contains("rsync") && !ideaScript.contains("project-remote"), "IdeaDesk start does not force restarts, build or sync")
    let runningIdea = try Controller.command("/bin/bash", ["-c", "curl() { return 0; }; launchctl() { echo UNEXPECTED_START; return 9; }; " + ideaScript], root: registry)
    try check(runningIdea.status == 0 && !runningIdea.output.contains("UNEXPECTED_START"), "Healthy IdeaDesk is not restarted")
    let stoppedIdea = try Controller.command("/bin/bash", ["-c", "reads=0; curl() { reads=$((reads+1)); test $reads -ge 3; }; launchctl() { printf '%s\\n' \"$*\"; }; sleep() { :; }; " + ideaScript], root: registry)
    try check(stoppedIdea.status == 0 && stoppedIdea.output.contains("com.jorgedelacruz.ideadesk") && stoppedIdea.output.contains("IdeaDesk is running"), "Stopped IdeaDesk starts the existing LaunchAgent and waits for health")
    let failedIdea = try Controller.command("/bin/bash", ["-c", "curl() { return 1; }; launchctl() { return 7; }; sleep() { :; }; " + ideaScript], root: registry)
    try check(failedIdea.status == 7, "LaunchAgent failure remains a failure")
    let unhealthyIdea = try Controller.command("/bin/bash", ["-c", "curl() { return 1; }; launchctl() { return 0; }; sleep() { :; }; " + ideaScript], root: registry)
    try check(unhealthyIdea.status == 1 && unhealthyIdea.output.contains("did not respond"), "Unhealthy startup cannot report success")
    try check(Controller.arguments(action: "stop", key: "all", projects: projects) == ["kill", "all"], "Stop all mapping")
    try check(Controller.arguments(action: "start", key: "alpha", projects: projects) == ["alpha"], "Start mapping")
    try check(Controller.arguments(action: "restart", key: "alpha", projects: projects) == ["restart", "alpha"], "Restart mapping")
    try check(Controller.arguments(action: "start", key: "unknown", projects: projects) == nil, "Reject unknown key")
    try check(Controller.arguments(action: "reset", key: "all", projects: projects) == nil, "Reject unsupported action")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Switchboard Test \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = "printf '%s\\n' \"$@\"\n[[ \"${1:-}\" != failure ]]\n"
    try fixture.write(to: root.appendingPathComponent("project-dev.sh"), atomically: true, encoding: .utf8)
    let log = root.appendingPathComponent("result.log")
    for args in [["alpha"], ["all"], ["kill", "alpha"], ["kill", "all"], ["restart", "alpha"]] {
        let code = try Controller.execute(root: root, arguments: args, log: log)
        let output = try String(contentsOf: log, encoding: .utf8)
        try check(code == 0 && output == args.joined(separator: "\n") + "\n", "Fixture dispatch: \(args)")
    }
    let failure = try Controller.execute(root: root, arguments: ["failure"], log: log)
    try check(failure == 1, "Preserve backend failure")
    let commandFailure = try Controller.executeCommand(root: root, executable: "/bin/bash", arguments: ["-c", "echo service-start-failed; exit 7"], log: log)
    let commandOutput = try String(contentsOf: log, encoding: .utf8)
    try check(commandFailure == 7 && commandOutput == "service-start-failed\n", "Service command preserves logs and exit status")
    print("Switchboard: isolated launcher and private portal checks passed; no real services changed.")
}

do {
    if CommandLine.arguments.contains("--self-test") { try selfTest(); try usageSelfTest(); try menuSelfTest(); try loginSelfTest(); exit(0) }
    if let index = CommandLine.arguments.firstIndex(of: "--capture-claude-usage"), CommandLine.arguments.count == index + 2 {
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 16384), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 262144 else { throw UsageError.invalidData }
        }
        let capture = try UsageReader.captureClaude(data: data, destination: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        let text = capture.windows.map { "\($0.name): \(Int($0.usedPercent.rounded()))%" }.joined(separator: " · ")
        print(text.isEmpty ? "Switchboard · Quota pending" : text)
        exit(0)
    }
    guard let path = Bundle.main.object(forInfoDictionaryKey: "ProjectsWorkspaceRoot") as? String,
          let appPath = Bundle.main.object(forInfoDictionaryKey: "ProjectsAppRoot") as? String else {
        throw NSError(domain: "Switchboard", code: 5, userInfo: [NSLocalizedDescriptionKey: "Rebuild with switchboard build."])
    }
    if let index = CommandLine.arguments.firstIndex(of: "--login") {
        guard CommandLine.arguments.count == index + 2 else { throw CocoaError(.validationMissingMandatoryProperty) }
        let service = LoginService.live(appRoot: URL(fileURLWithPath: appPath))
        let action = CommandLine.arguments[index + 1]
        if action == "migration-plan" { print(service.migrationPlan()); exit(0) }
        let report: LoginDiagnostic
        switch action {
        case "status", "diagnostic": report = service.diagnostic()
        case "register": report = service.change(enabled: true)
        case "unregister": report = service.change(enabled: false)
        default: throw NSError(domain: "Login", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown login action."])
        }
        print(report.json()); exit(report.exitCode)
    }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    if CommandLine.arguments.contains("--ai-snapshot") {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(UsageReader.all(root: root, appRoot: URL(fileURLWithPath: appPath), liveCodex: CommandLine.arguments.contains("--live-codex"))), as: UTF8.self)); exit(0)
    }
    if CommandLine.arguments.contains("--snapshot") {
        let appRootURL = URL(fileURLWithPath: appPath)
        let role: MachineRole
        if CommandLine.arguments.contains("--client") { role = .client }
        else if CommandLine.arguments.contains("--host") { role = .host }
        else { role = Controller.detectRole(root: root, appRoot: appRootURL) }
        let (values, _) = try Controller.snapshot(root: root, role: role)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(values), as: UTF8.self)); exit(0)
    }
    let application = NSApplication.shared
    if NSRunningApplication.runningApplications(withBundleIdentifier: "com.jorgedelacruz.projects-menu").contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { exit(0) }
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate(root: root, appRoot: URL(fileURLWithPath: appPath, isDirectory: true))
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
} catch {
    fputs("Switchboard: \(error.localizedDescription)\n", stderr)
    exit(1)
}
