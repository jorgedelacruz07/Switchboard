import Foundation

enum MenuGroup {
    case projects, services, archived
}

// Which projects the owner hid and in which order the rest appear. Stored in .local/settings.json.
struct MenuPreferences: Equatable {
    var hidden: Set<String>
    var order: [String]

    static func settingsFile(appRoot: URL) -> URL {
        appRoot.appendingPathComponent(".local/settings.json")
    }

    static func load(appRoot: URL) -> MenuPreferences {
        guard let data = try? Data(contentsOf: settingsFile(appRoot: appRoot)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MenuPreferences(hidden: [], order: [])
        }
        let hidden = (json["hiddenProjects"] as? [String]) ?? []
        let order = (json["projectOrder"] as? [String]) ?? []
        return MenuPreferences(hidden: Set(hidden), order: order)
    }

    // Merges into the existing file so role, workspaceRoot and any other key survive. A file
    // that exists but is not a JSON object is left alone and reported, never overwritten.
    func save(appRoot: URL) throws {
        let file = Self.settingsFile(appRoot: appRoot)
        var json: [String: Any] = [:]
        if let existing = try? Data(contentsOf: file), !existing.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw NSError(domain: "Switchboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(file.path) is not a valid JSON object; fix or remove it, then save again. Nothing was written."])
            }
            json = parsed
        }
        json["hiddenProjects"] = hidden.sorted()
        json["projectOrder"] = order
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: file, options: .atomic)
    }

    // Keys listed in order come first, in that order; everything else keeps its original order.
    func ordered(_ statuses: [ProjectStatus]) -> [ProjectStatus] {
        var remaining = statuses
        var result: [ProjectStatus] = []
        for key in order {
            if let index = remaining.firstIndex(where: { $0.project.key == key }) {
                result.append(remaining.remove(at: index))
            }
        }
        return result + remaining
    }
}

enum MenuModel {
    static func group(of project: Project) -> MenuGroup {
        if project.archived { return .archived }
        return .projects
    }

    // In use means not stopped. Only active development projects count; hidden ones leave both numbers.
    static func counter(_ statuses: [ProjectStatus], prefs: MenuPreferences) -> (inUse: Int, total: Int, hidden: Int) {
        let projects = statuses.filter { group(of: $0.project) == .projects && $0.project.launcherManaged && !$0.project.isService }
        let hidden = projects.filter { prefs.hidden.contains($0.project.key) }.count
        let visible = projects.filter { !prefs.hidden.contains($0.project.key) }
        return (visible.filter { $0.state != .off }.count, visible.count, hidden)
    }

    static func remoteStartEnabled(busy: Bool, refreshFailed: Bool) -> Bool {
        !busy && !refreshFailed
    }

    static func stateLabel(_ status: ProjectStatus, role: MachineRole) -> String {
        if status.project.archived { return "Archived" }
        if !status.project.hasServer {
            if let git = status.git {
                if git.dirty > 0 && git.ahead > 0 { return "Modified & Unpushed" }
                if git.dirty > 0 { return "Modified" }
                if git.ahead > 0 { return "Unpushed" }
                if git.behind > 0 { return "Needs Pull" }
                return "Clean"
            }
            return ""
        }
        guard role == .client else { return status.state.label }
        if !status.project.launcherManaged { return status.state.label }
        if status.project.ports.isEmpty { return status.state == .on ? "Running on Mac Mini" : "Stopped" }
        if status.state == .on { return "Running & Tunneled" }
        if status.state == .partial { return "Remote Running" }
        return "Stopped"
    }

    static func rowTitle(_ status: ProjectStatus, role: MachineRole) -> String {
        var parts = [status.project.name]
        let label = stateLabel(status, role: role)
        if !label.isEmpty && status.project.hasServer {
            parts.append(label)
        }
        if status.project.webPort > 0 { parts.append(":\(status.project.webPort)") }
        if let git = status.git {
            if git.dirty > 0 && git.ahead > 0 {
                parts.append("±\(git.dirty) ↑\(git.ahead)")
            } else if git.dirty > 0 {
                parts.append("±\(git.dirty)")
            } else if git.ahead > 0 {
                parts.append("↑\(git.ahead)")
            } else if git.behind > 0 {
                parts.append("↓\(git.behind)")
            } else if !status.project.hasServer && !git.branch.isEmpty {
                parts.append(git.branch)
            }
        }
        return parts.joined(separator: " · ")
    }

    static func openLinks(entry: RegistryEntry?, docsPage: URL?) -> [(title: String, url: URL)] {
        var links: [(title: String, url: URL)] = []
        if let url = entry?.links.production { links.append(("Open Production — \(url.host ?? url.absoluteString)", url)) }
        if let url = entry?.links.api { links.append(("Open Production API — \(url.host ?? url.absoluteString)", url)) }
        if let url = entry?.links.repo { links.append(("Open Repository", url)) }
        if let url = docsPage { links.append(("Open in ProjectsDocs", url)) }
        return links
    }
}
