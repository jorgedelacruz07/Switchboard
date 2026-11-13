import AppKit
import Darwin

struct Project: Codable {
    let key: String
    let directory: String
    let ports: [Int]
    let webPort: Int
    // False for registry-only services (for example a LaunchAgent) that project-dev.sh cannot start or stop.
    var launcherManaged = true
    var archived = false
    // Registry kind (product, system, archive, ...); launcher-only projects default to product.
    var kind = "product"
    var title: String? = nil
    var isDocsPortal: Bool { key == "registry-projectsdocs" && !archived }
    var isIdeaDesk: Bool { key == "ideadesk" && !archived }
    var isService: Bool { isIdeaDesk || isDocsPortal || kind == "system" }
    var hasServer: Bool { launcherManaged || isIdeaDesk || isDocsPortal || !ports.isEmpty }
    var name: String { title ?? String(directory.split(separator: "/").first ?? Substring(key)) }
    var webURL: URL? { webPort > 0 ? URL(string: "http://localhost:\(webPort)") : nil }
    var portLabel: String { webPort > 0 ? " :\(webPort)" : "" }
}

enum ProjectState: String, Codable {
    case on, partial, off, archived
    var label: String {
        switch self {
        case .on: return "Running"
        case .partial: return "Partial"
        case .archived: return "Archived"
        case .off: return "Stopped"
        }
    }
    var color: NSColor {
        switch self {
        case .on: return .systemGreen
        case .partial: return .systemOrange
        case .archived: return .tertiaryLabelColor
        case .off: return .secondaryLabelColor
        }
    }
}

enum MachineRole: String, Codable {
    case host, client
}

struct RemoteStatus: Codable {
    var hostReachable: Bool = false
    var devTunnelActive: Bool = false
    var devTunnelPID: Int? = nil
    var dockerTunnelActive: Bool = false
    var dockerTunnelPID: Int? = nil
    var remoteDevKeys: [String] = []
    var localMongoActive: Bool = false
    var localRedisActive: Bool = false
}

struct RepoGitStatus: Codable, Equatable {
    let name: String
    let path: String
    let branch: String
    let dirty: Int
    let ahead: Int
    let behind: Int
    let samples: [String]
}

struct ProjectGitStatus: Codable, Equatable {
    let dirty: Int
    let ahead: Int
    let behind: Int
    let branch: String
    let repos: [RepoGitStatus]

    var isClean: Bool { dirty == 0 && ahead == 0 && behind == 0 }
}

struct ProjectStatus: Codable {
    let project: Project
    let state: ProjectState
    let listening: [Int]
    var liveSyncAlive: Bool = false
    var tunnelListening: Bool = false
    var git: ProjectGitStatus? = nil
}

struct WorkspaceHandoffStatus: Codable {
    let version: Int
    let owner: MachineRole
    let phase: String
    let target: MachineRole?
    let updatedAt: String?
    let blockers: [String]
    let initialOwner: String?
    var localRole: MachineRole?
    var localOwnsWorkspace: Bool?

    var ownerName: String { owner == .client ? "MacBook Air" : "Mac Mini" }
    var targetName: String? { target.map { $0 == .client ? "MacBook Air" : "Mac Mini" } }
    var isReady: Bool { phase == "ready" }
    var canHandOff: Bool { owner == localRole && phase != "syncing" }
}

struct CommandResult {
    let status: Int32
    let output: String
}

enum Controller {
    static let logDirectory = URL(fileURLWithPath: "/tmp/project-dev-logs", isDirectory: true)
    static func environment(root: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/share/mise/shims:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["ROOT"] = root.path
        env["LOG_DIR"] = logDirectory.path
        env["NO_COLOR"] = "1"
        env["NO_OPEN"] = "1"
        return env
    }

    static func command(_ executable: String, _ arguments: [String], root: URL) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = environment(root: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func detectRole(root: URL, appRoot: URL) -> MachineRole {
        let settingsFile = appRoot.appendingPathComponent(".local/settings.json")
        if let data = try? Data(contentsOf: settingsFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let roleStr = json["role"] as? String,
           let role = MachineRole(rawValue: roleStr) {
            return role
        }
        let host = ProcessInfo.processInfo.hostName.lowercased()
        if host.contains("mac-mini") || host.contains("macmini") {
            return .host
        }
        return .client
    }

    static func saveRole(_ role: MachineRole, appRoot: URL) {
        let settingsFile = appRoot.appendingPathComponent(".local/settings.json")
        var data: [String: Any] = [:]
        if let existing = try? Data(contentsOf: settingsFile),
           let json = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            data = json
        }
        data["role"] = role.rawValue
        if let out = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]) {
            try? FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? out.write(to: settingsFile)
        }
    }

    static func checkRemote(root: URL) -> RemoteStatus {
        var status = RemoteStatus()
        if let res = try? command("/usr/bin/pgrep", ["-f", "ssh.*macmini-tunnel"], root: root),
           res.status == 0 {
            let pids = res.output.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if let first = pids.first {
                status.devTunnelActive = true
                status.devTunnelPID = first
            }
        }
        if let res = try? command("/usr/bin/pgrep", ["-f", "ssh.*macmini-docker"], root: root),
           res.status == 0 {
            let pids = res.output.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if let first = pids.first {
                status.dockerTunnelActive = true
                status.dockerTunnelPID = first
            }
        }
        if let ping = try? command("/usr/bin/ssh", ["-o", "ConnectTimeout=2", "-o", "BatchMode=yes", "macmini", "echo 1; ls -1 /tmp/project-dev-logs/*-dev.pid 2>/dev/null"], root: root) {
            let lines = ping.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let first = lines.first, first == "1" {
                status.hostReachable = true
                for line in lines.dropFirst() {
                    if line.hasPrefix("/tmp/project-dev-logs/") && line.hasSuffix("-dev.pid") {
                        let key = String(line.dropFirst("/tmp/project-dev-logs/".count).dropLast("-dev.pid".count))
                        if !key.isEmpty {
                            status.remoteDevKeys.append(key)
                        }
                    }
                }
            }
        }
        return status
    }

    static func isLiveSyncAlive(projectName: String) -> Bool {
        let pidFile = URL(fileURLWithPath: "/tmp/project-remote-sync-\(projectName).pid")
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return false }
        return kill(pid, 0) == 0
    }

    static func parseCatalog(_ text: String) throws -> [Project] {
        let projects = try text.split(separator: "\n").map { line -> Project in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[0].isEmpty, !fields[1].isEmpty,
                  (fields[3].isEmpty || Int(fields[3]).map { (1...65535).contains($0) } == true) else {
                throw NSError(domain: "Switchboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid project catalog."])
            }
            let ports = try fields[2...3].filter { !$0.isEmpty }.map { value -> Int in
                guard let port = Int(value), (1...65535).contains(port) else {
                    throw NSError(domain: "Switchboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid project port."])
                }
                return port
            }
            // IdeaDesk serves its built UI from the catalog API port through
            // its existing LaunchAgent. It must never enter generic Work/Sync.
            if fields[0] == "ideadesk" {
                guard let servicePort = Int(fields[2]) else {
                    throw NSError(domain: "Switchboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "IdeaDesk requires its service port in the launcher catalog."])
                }
                return Project(key: fields[0], directory: fields[1], ports: [servicePort], webPort: servicePort, launcherManaged: false)
            }
            let webPort = Int(fields[3]) ?? 0
            return Project(key: fields[0], directory: fields[1], ports: ports, webPort: webPort)
        }
        guard !projects.isEmpty, Set(projects.map(\.key)).count == projects.count else {
            throw NSError(domain: "Switchboard", code: 3, userInfo: [NSLocalizedDescriptionKey: "The project catalog is empty or contains duplicate keys."])
        }
        return projects
    }

    static func catalog(root: URL) throws -> [Project] {
        let result = try command("/bin/bash", [root.appendingPathComponent("project-dev.sh").path, "catalog"], root: root)
        guard result.status == 0 else {
            throw NSError(domain: "Switchboard", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: "Could not read project-dev catalog."])
        }
        return try parseCatalog(result.output)
    }

    // Registry projects (and workspace root) not known to the launcher catalog.
    static func registryServices(root: URL, excluding projects: [Project]) -> [Project] {
        let file = root.appendingPathComponent("workspace.registry.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["projects"] as? [[String: Any]] else { return [] }
        let known = Set(projects.map { $0.name.lowercased() } + projects.map { $0.directory.lowercased() } + projects.map { $0.key.lowercased() })
        var services = entries.compactMap { entry -> Project? in
            let kind = entry["kind"] as? String ?? "product"
            let archived = kind == "archive"
            guard let id = entry["id"] as? String, let name = entry["name"] as? String,
                  let projectRoot = entry["projectRoot"] as? String else { return nil }
            let folder = (projectRoot as NSString).lastPathComponent.lowercased()
            if known.contains(folder) || known.contains(name.lowercased()) || known.contains(id.lowercased()) {
                return nil
            }
            if archived { return Project(key: "registry-\(id)", directory: name, ports: [], webPort: 0, launcherManaged: false, archived: true, kind: "archive", title: name) }
            let port: Int
            if let text = entry["ports"] as? String,
               let match = text.range(of: ":[0-9]{2,5}(?![0-9])", options: .regularExpression),
               let p = Int(text[match].dropFirst()), (1...65535).contains(p) {
                port = p
            } else {
                port = 0
            }
            let dir = (projectRoot as NSString).lastPathComponent
            return Project(key: "registry-\(id)", directory: dir.isEmpty ? name : dir, ports: port > 0 ? [port] : [], webPort: port, launcherManaged: false, kind: kind, title: name)
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) && !known.contains("projects") && !known.contains("workspace-root") {
            services.append(Project(key: "workspace-root", directory: "Projects", ports: [], webPort: 0, launcherManaged: false, kind: "system", title: "Projects"))
        }
        return services.filter { !$0.archived } + services.filter(\.archived)
    }

    // Reuse the private origin owned by ProjectsDocs; never open its public copy.
    static func portalURL(root: URL) -> URL? {
        let file = root.appendingPathComponent("ProjectsDocs/docs.config.json")
        guard let data = try? Data(contentsOf: file),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origin = config["ideaDeskUrl"] as? String,
              var components = URLComponents(string: origin),
              components.scheme == "https", components.host != nil,
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil else { return nil }
        components.path = "/docs/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func portalStartCommand(role: MachineRole) -> (executable: String, arguments: [String]) {
        let start = "launchctl kickstart \"gui/$(id -u)/com.jorgedelacruz.projects-docs\""
        if role == .client {
            return ("/usr/bin/ssh", ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "macmini", start])
        }
        return ("/bin/bash", ["-c", start])
    }

    static func ideaDeskURL(root: URL) -> URL? {
        ideaDeskURL(portal: portalURL(root: root))
    }

    // Same URL from a portal base that the caller already read.
    static func ideaDeskURL(portal: URL?) -> URL? {
        guard let portal, var url = URLComponents(url: portal, resolvingAgainstBaseURL: false) else { return nil }
        url.path = "/"
        return url.url
    }

    static func ideaDeskStartCommand(role: MachineRole) -> (executable: String, arguments: [String]) {
        // No forced restart, build, transfer or second process. A running
        // service stays untouched, including active discussions and planning.
        let start = """
        set -e
        site=http://127.0.0.1:5180
        if curl -fsS --max-time 3 -o /dev/null "$site/"; then
          echo 'IdeaDesk is already running; Live Sync is disabled.'
          exit 0
        fi
        launchctl kickstart "gui/$(id -u)/com.jorgedelacruz.ideadesk"
        for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
          if curl -fsS --max-time 2 -o /dev/null "$site/"; then
            echo 'IdeaDesk is running; Live Sync is disabled.'
            exit 0
          fi
          sleep 1
        done
        echo 'IdeaDesk did not respond. Inspect /tmp/ideadesk-server.log.' >&2
        exit 1
        """
        if role == .client {
            return ("/usr/bin/ssh", ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "macmini", start])
        }
        return ("/bin/bash", ["-c", start])
    }

    static func listeningPorts(_ text: String) -> Set<Int> {
        Set(text.split(separator: "\n").compactMap { line in
            guard line.first == "n", let last = line.split(separator: ":").last else { return nil }
            return Int(last)
        })
    }

    static func state(project: Project, listening: Set<Int>, launcherAlive: Bool, git: ProjectGitStatus? = nil) -> ProjectStatus {
        if project.archived { return ProjectStatus(project: project, state: .archived, listening: [], git: git) }
        if !project.hasServer { return ProjectStatus(project: project, state: .off, listening: [], git: git) }
        if project.ports.isEmpty {
            return ProjectStatus(project: project, state: launcherAlive ? .on : .off, listening: [], git: git)
        }
        let active = project.ports.filter { listening.contains($0) }
        let state: ProjectState = active.count == project.ports.count ? .on : (!active.isEmpty || launcherAlive ? .partial : .off)
        return ProjectStatus(project: project, state: state, listening: active, git: git)
    }

    static func workspaceGitStatuses(root: URL, appRoot: URL?) -> [String: ProjectGitStatus] {
        guard let appRoot = appRoot ?? (FileManager.default.fileExists(atPath: root.appendingPathComponent("Switchboard").path) ? root.appendingPathComponent("Switchboard") : nil) else {
            return [:]
        }
        let helper = appRoot.appendingPathComponent("scripts/project-git-status.py")
        guard FileManager.default.fileExists(atPath: helper.path) else { return [:] }
        guard let result = try? command("/usr/bin/python3", [helper.path, "--root", root.path], root: root),
              result.status == 0,
              let data = result.output.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: ProjectGitStatus].self, from: data) else {
            return [:]
        }
        return map
    }

    static func snapshot(root: URL, appRoot: URL? = nil, role: MachineRole) throws -> ([ProjectStatus], RemoteStatus) {
        let projects = try catalog(root: root)
        let result = try command("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-Fpn"], root: root)
        guard result.status == 0 || (result.status == 1 && result.output.isEmpty) else {
            throw NSError(domain: "Switchboard", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not read listening ports."])
        }
        let ports = listeningPorts(result.output)
        let allProjects = projects + registryServices(root: root, excluding: projects)
        var remoteStatus = role == .client ? checkRemote(root: root) : RemoteStatus()
        if role == .host {
            remoteStatus.localMongoActive = ports.contains(27018)
            remoteStatus.localRedisActive = ports.contains(6380)
        }
        let gitMap = workspaceGitStatuses(root: root, appRoot: appRoot)

        let statuses = allProjects.map { project -> ProjectStatus in
            let cleanKey = project.key.hasPrefix("registry-") ? String(project.key.dropFirst("registry-".count)) : project.key
            let git = gitMap[project.key.lowercased()]
                ?? gitMap[cleanKey.lowercased()]
                ?? gitMap[project.name.lowercased()]
                ?? gitMap[project.directory.lowercased()]
            if role == .client {
                if project.isDocsPortal || project.isIdeaDesk {
                    let serviceURL = project.isIdeaDesk ? ideaDeskURL(root: root) : portalURL(root: root)
                    let response = serviceURL.flatMap { url in
                        try? command("/usr/bin/curl", ["--noproxy", "*", "--connect-timeout", "2", "--max-time", "3", "-fsS", "-o", "/dev/null", url.absoluteString], root: root)
                    }
                    return ProjectStatus(project: project, state: response?.status == 0 ? .on : .off, listening: [], git: git)
                }
                if !project.hasServer {
                    return ProjectStatus(project: project, state: .off, listening: [], git: git)
                }
                let syncAlive = isLiveSyncAlive(projectName: project.name)
                let remoteRunning = remoteStatus.remoteDevKeys.contains(project.key)
                let active = project.ports.filter { ports.contains($0) }
                let state: ProjectState
                if project.archived {
                    state = .archived
                } else if project.ports.isEmpty {
                    state = remoteRunning ? .on : .off
                } else if remoteRunning && remoteStatus.devTunnelActive && !active.isEmpty {
                    state = .on
                } else if remoteRunning {
                    state = .partial
                } else {
                    state = .off
                }

                return ProjectStatus(project: project, state: state, listening: active, liveSyncAlive: syncAlive, tunnelListening: !active.isEmpty, git: git)
            } else {
                let file = logDirectory.appendingPathComponent("\(project.key)-dev.pid")
                let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let alive = Int32(text).map { $0 > 1 && kill($0, 0) == 0 } ?? false
                return state(project: project, listening: ports, launcherAlive: alive, git: git)
            }
        }
        return (statuses, remoteStatus)
    }

    static func snapshot(root: URL, role: MachineRole) throws -> ([ProjectStatus], RemoteStatus) {
        try snapshot(root: root, appRoot: nil, role: role)
    }

    static func snapshot(root: URL) throws -> [ProjectStatus] {
        let (statuses, _) = try snapshot(root: root, role: .host)
        return statuses
    }

    static func workspaceHandoff(root: URL, appRoot: URL, role: MachineRole) throws -> WorkspaceHandoffStatus {
        let helper = appRoot.appendingPathComponent("scripts/workspace-handoff.py")
        guard FileManager.default.isExecutableFile(atPath: helper.path) || FileManager.default.fileExists(atPath: helper.path) else {
            throw NSError(domain: "Switchboard", code: 8, userInfo: [NSLocalizedDescriptionKey: "Workspace handoff helper is missing. Rebuild and install Switchboard on both Macs."])
        }
        let result = try command("/usr/bin/python3", [helper.path, "--root", root.path, "--role", role.rawValue, "--status"], root: root)
        guard result.status == 0, let data = result.output.data(using: .utf8) else {
            throw NSError(domain: "Switchboard", code: 9, userInfo: [NSLocalizedDescriptionKey: result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Could not read workspace baton status." : result.output.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return try JSONDecoder().decode(WorkspaceHandoffStatus.self, from: data)
    }

    struct RemoteWorkAction {
        let script: String
        let arguments: [String]
    }

    static func remoteWorkAction(action: String, key: String, projects: [Project]) -> RemoteWorkAction? {
        guard key == "all" || projects.contains(where: { $0.key == key && $0.launcherManaged && !$0.archived }) else { return nil }
        switch action {
        case "start": return RemoteWorkAction(script: "project-remote.sh", arguments: ["work", key])
        case "stop": return RemoteWorkAction(script: "project-remote.sh", arguments: ["work", "stop", key])
        default: return nil
        }
    }

    static func remoteDirectoryCommand(project: Project) throws -> String {
        let directory = project.key == "workspace-root" ? "." : project.directory
        guard !directory.isEmpty, !directory.hasPrefix("/"),
              !directory.split(separator: "/").contains(".."),
              !directory.contains("\n"), !directory.contains("\0") else {
            throw NSError(domain: "Switchboard", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid remote project directory."])
        }
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "CDPATH= cd \"$HOME/Projects\" && CDPATH= cd -- " + quoted + " && pwd -P"
    }

    static func cursorArguments(remotePath: String) throws -> [String] {
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0") else {
            throw NSError(domain: "Switchboard", code: 11, userInfo: [NSLocalizedDescriptionKey: "Mini returned an invalid project path."])
        }
        return ["--remote", "ssh-remote+macmini", path]
    }

    static func openRemoteProject(root: URL, project: Project, log: URL,
                                  cursorExecutable: String? = nil,
                                  resolve: ((String, [String]) throws -> CommandResult)? = nil) throws -> Int32 {
        let remoteCommand = try remoteDirectoryCommand(project: project)
        let run = resolve ?? { executable, arguments in try command(executable, arguments, root: root) }
        let result = try run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "macmini", remoteCommand])
        guard result.status == 0 else {
            try Data(result.output.utf8).write(to: log)
            return result.status
        }
        let arguments = try cursorArguments(remotePath: result.output)
        let paths = (environment(root: root)["PATH"] ?? "").split(separator: ":").map { "\($0)/cursor" }
            + ["/Applications/Cursor.app/Contents/Resources/app/bin/cursor"]
        guard let executable = cursorExecutable ?? paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "Switchboard", code: 12, userInfo: [NSLocalizedDescriptionKey: "Cursor CLI unavailable. Enable its cursor shell command or install Cursor in Applications."])
        }
        // Process.arguments preserves spaces, quotes and shell metacharacters literally.
        return try executeCommand(root: root, executable: executable, arguments: arguments, log: log)
    }

    static func arguments(action: String, key: String, projects: [Project]) -> [String]? {
        guard key == "all" || projects.contains(where: { $0.key == key && $0.launcherManaged }) else { return nil }
        switch action {
        case "start": return [key]
        case "stop": return ["kill", key]
        case "restart" where key != "all": return ["restart", key]
        default: return nil
        }
    }

    // File output avoids a pipe being held open by a development server's children.
    static func execute(root: URL, script: String, arguments: [String], log: URL) throws -> Int32 {
        try executeCommand(root: root, executable: "/bin/bash", arguments: [root.appendingPathComponent(script).path] + arguments, log: log)
    }

    static func executeCommand(root: URL, executable: String, arguments: [String], log: URL) throws -> Int32 {
        if !FileManager.default.fileExists(atPath: log.path) {
            guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let file = try FileHandle(forWritingTo: log)
        defer { try? file.close() }
        try file.truncate(atOffset: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = environment(root: root)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = file
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func execute(root: URL, arguments: [String], log: URL) throws -> Int32 {
        try execute(root: root, script: "project-dev.sh", arguments: arguments, log: log)
    }
}
