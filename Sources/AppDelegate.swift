import AppKit
import Darwin
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Provider and quota probes can each create short-lived helpers. Keep them
    // sequential so startup and manual refreshes do not stack their peak memory.
    private static let aiRefreshQueue = DispatchQueue(label: "projects.menu.ai-refresh", qos: .utility)

    let root: URL
    let appRoot: URL
    var role: MachineRole
    var remoteStatus = RemoteStatus()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let worker = DispatchQueue(label: "projects.menu.actions", qos: .utility)
    var statuses: [ProjectStatus] = []
    var loginReport: LoginDiagnostic?
    var loginService: LoginService { LoginService.live(appRoot: appRoot) }
    var busy: String?
    var lastMessage = "Choose a project to start or stop"
    var refreshError: String?
    var refreshing = false
    var tracking = false
    var timer: Timer?
    var usageTimer: Timer?
    var providerStatusTimer: Timer?
    var usage: [AIUsage] = []
    var usageRefreshing = false
    var lastUsageRefresh: Date?
    var lastAccountRefresh: Date?
    var usageEnabled = UserDefaults.standard.object(forKey: "miniBarAIEnabled") as? Bool ?? true
    var providerStatuses: [AIProviderStatus] = []
    var providerStatusError: String?
    var providerStatusRefreshing = false
    var lastProviderStatusRefresh: Date?
    var providerStatusEnabled = UserDefaults.standard.object(forKey: "switchboardProviderStatusEnabled") as? Bool ?? false
    var resultWindow: NSWindow?
    // Per-machine visibility and order of the Projects group (.local/settings.json).
    var prefs: MenuPreferences
    // Read in refresh() next to the snapshot, never on every rebuildMenu().
    var registryEntries: [String: RegistryEntry] = [:]
    // Private ProjectsDocs origin (docs.config.json), read with the registry; menu rows reuse it.
    var portalBase: URL?
    // Held only while the "Configure Projects" window is open; released in onClosed.
    var settingsController: ProjectSettingsController?
    // True from the start of a registry save until its result is back on the main thread,
    // even if its window was closed meanwhile; no new window opens while it is set.
    var registrySaving = false
    let actionLog = Controller.logDirectory.appendingPathComponent("menu-action.log")

    init(root: URL, appRoot: URL) {
        self.root = root
        self.appRoot = appRoot
        self.role = Controller.detectRole(root: root, appRoot: appRoot)
        self.prefs = MenuPreferences.load(appRoot: appRoot)
        super.init()
    }

    func updateStatusItemAppearance() {
        if role == .client {
            statusItem.button?.image = NSImage(systemSymbolName: "laptopcomputer.and.arrow.forward", accessibilityDescription: "Switchboard (Client)") ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Switchboard")
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Switchboard")
        }
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = " …"
        statusItem.button?.setAccessibilityLabel("Switchboard")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateStatusItemAppearance()
        rebuildMenu()
        refresh()
        refreshUsage()
        refreshProviderStatus()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshUsage() }
        usageTimer?.tolerance = 30
        providerStatusTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshProviderStatus() }
        providerStatusTimer?.tolerance = 30
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 10
    }

    func menuWillOpen(_ menu: NSMenu) { tracking = true; refresh() }
    func menuDidClose(_ menu: NSMenu) {
        tracking = false
        DispatchQueue.main.async { if !self.tracking { self.rebuildMenu() } }
    }

    @objc func refreshUsage() {
        guard usageEnabled, !usageRefreshing, lastUsageRefresh.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        usageRefreshing = true
        lastUsageRefresh = Date()
        if !tracking { rebuildMenu() }
        Self.aiRefreshQueue.async {
            let values = UsageReader.all(root: self.root, appRoot: self.appRoot)
            DispatchQueue.main.async {
                self.usage = values
                self.usageRefreshing = false
                if !self.tracking { self.rebuildMenu() }
            }
        }
    }

    @objc func toggleUsage() {
        usageEnabled.toggle()
        UserDefaults.standard.set(usageEnabled, forKey: "miniBarAIEnabled")
        if usageEnabled { lastUsageRefresh = nil; refreshUsage() }
        rebuildMenu()
    }

    @objc func refreshProviderStatus() {
        guard providerStatusEnabled, !providerStatusRefreshing,
              lastProviderStatusRefresh.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        providerStatusRefreshing = true
        if !tracking { rebuildMenu() }
        Self.aiRefreshQueue.async {
            let result = Result { try AIProviderStatusReader.all(appRoot: self.appRoot) }
            DispatchQueue.main.async {
                self.providerStatusRefreshing = false
                self.lastProviderStatusRefresh = Date()
                switch result {
                case .success(let values):
                    self.providerStatuses = values
                    self.providerStatusError = nil
                case .failure(let error):
                    self.providerStatusError = error.localizedDescription
                }
                if !self.tracking { self.rebuildMenu() }
            }
        }
    }

    @objc func toggleProviderStatus() {
        providerStatusEnabled.toggle()
        UserDefaults.standard.set(providerStatusEnabled, forKey: "switchboardProviderStatusEnabled")
        if providerStatusEnabled { lastProviderStatusRefresh = nil; refreshProviderStatus() }
        rebuildMenu()
    }

    @objc func refreshCodexAccount() {
        guard usageEnabled, !usageRefreshing, lastAccountRefresh.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastAccountRefresh = Date()
        usageRefreshing = true
        rebuildMenu()
        Self.aiRefreshQueue.async {
            let value = UsageReader.codex(root: self.root, live: true)
            DispatchQueue.main.async {
                if let index = self.usage.firstIndex(where: { $0.id == "codex" }) { self.usage[index] = value }
                self.usageRefreshing = false
                if !self.tracking { self.rebuildMenu() }
            }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let root = self.root
        let currentAppRoot = self.appRoot
        let currentRole = self.role
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Controller.snapshot(root: root, appRoot: currentAppRoot, role: currentRole) }
            // A missing or malformed registry yields no entries: the menu renders without links.
            let entries = Registry.entries(root: root)
            let portal = Controller.portalURL(root: root)
            let loginReport = self.loginService.diagnostic()
            DispatchQueue.main.async {
                self.loginReport = loginReport
                self.refreshing = false
                if self.usageEnabled, let index = self.usage.firstIndex(where: { $0.id == "claude" }) {
                    self.usage[index] = UsageReader.claude(appRoot: self.appRoot)
                }
                switch result {
                case .success(let (values, remote)):
                    self.statuses = values
                    self.remoteStatus = remote
                    self.refreshError = nil
                case .failure(let error):
                    self.refreshError = error.localizedDescription
                }
                self.registryEntries = entries
                self.portalBase = portal
                self.updateStatusTitle()
                if !self.tracking { self.rebuildMenu() }
            }
        }
    }

    func updateStatusTitle() {
        let count = MenuModel.counter(statuses, prefs: prefs)
        let hiddenNote = count.hidden > 0 ? " · \(count.hidden) hidden" : ""
        let dirtyProjects = statuses.filter { ($0.git?.dirty ?? 0) > 0 || ($0.git?.ahead ?? 0) > 0 }
        let gitNote = dirtyProjects.isEmpty ? "" : " · \(dirtyProjects.count) pending git"
        let summary = "Switchboard · \(count.inUse) of \(count.total) projects active\(hiddenNote)\(gitNote)"
        if role == .client {
            statusItem.button?.title = busy != nil ? " ⏳" : (refreshError != nil ? " !" : " ⚡ \(count.inUse)/\(count.total)")
            statusItem.button?.toolTip = busy ?? "\(summary) · Tunnel: \(remoteStatus.devTunnelActive ? "Active" : "Off")"
        } else {
            statusItem.button?.title = busy != nil ? " ⏳" : (refreshError != nil ? " !" : " \(count.inUse)/\(count.total)")
            statusItem.button?.toolTip = busy ?? summary
        }
    }

    @discardableResult
    func item(_ title: String, in menu: NSMenu, action: Selector? = nil, value: Any? = nil, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.isEnabled = enabled && action != nil
        menu.addItem(item)
        return item
    }

    // Workspace ownership is global; project rows describe runtime only.
    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        appendWorkspaceHandoff(to: menu)
        menu.addItem(.separator())
        appendProjectsGroup(to: menu)
        menu.addItem(.separator())
        appendAIUsage(to: menu)
        menu.addItem(.separator())
        appendServicesGroup(to: menu)
        statusItem.menu = menu
    }

    func appendWorkspaceHandoff(to menu: NSMenu) {
        item("Workspace files · Mac Mini", in: menu)
        item(role == .client ? "Edit through Cursor Remote SSH" : "Authoritative working files on this Mac", in: menu)
    }

    // MARK: Projects group

    func appendProjectsGroup(to menu: NSMenu) {
        let count = MenuModel.counter(statuses, prefs: prefs)
        item("Projects · \(count.inUse) of \(count.total) active", in: menu)
        if let busy {
            item(busy, in: menu)
        } else if refreshError != nil {
            item("Status unavailable · see View Last Result…", in: menu)
        }

        let visible = prefs.ordered(statuses).filter { !prefs.hidden.contains($0.project.key) }
        for status in visible where MenuModel.group(of: status.project) == .projects {
            menu.addItem(projectRow(status))
        }
        let archived = visible.filter { MenuModel.group(of: $0.project) == .archived }
        if !archived.isEmpty {
            let row = NSMenuItem(title: "Archived (\(archived.count))", action: nil, keyEquivalent: "")
            row.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Archived")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor]))
            let sub = NSMenu()
            sub.autoenablesItems = false
            for status in archived { sub.addItem(projectRow(status)) }
            row.submenu = sub
            menu.addItem(row)
        }
        menu.addItem(projectActionsItem())
    }

    func projectRow(_ status: ProjectStatus) -> NSMenuItem {
        let row = NSMenuItem(title: MenuModel.rowTitle(status, role: role), action: nil, keyEquivalent: "")
        row.image = statusImage(status)
        row.submenu = projectSubmenu(status)
        return row
    }

    func statusImage(_ status: ProjectStatus) -> NSImage? {
        let project = status.project
        let color: NSColor
        let symbol: String
        if project.archived {
            color = .tertiaryLabelColor; symbol = "archivebox"
        } else if !project.hasServer {
            symbol = "arrow.triangle.branch"
            if let git = status.git {
                if git.dirty > 0 {
                    color = .systemOrange
                } else if git.ahead > 0 {
                    color = .systemBlue
                } else if git.behind > 0 {
                    color = .systemYellow
                } else {
                    color = .systemGreen
                }
            } else {
                color = .secondaryLabelColor
            }
        } else if role == .client {
            if !project.launcherManaged {
                color = status.state.color; symbol = "circle.fill"
            } else if status.state == .on {
                color = .systemGreen; symbol = "circle.fill"
            } else if status.state == .partial {
                color = .systemOrange; symbol = "circle.lefthalf.filled"
            } else {
                color = .secondaryLabelColor; symbol = "circle.fill"
            }
        } else {
            color = status.state.color
            symbol = status.state == .partial ? "circle.lefthalf.filled" : (status.state == .archived ? "archivebox" : "circle.fill")
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: MenuModel.stateLabel(status, role: role))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
    }

    // Production, API, repository and ProjectsDocs rows; links that are not configured are omitted.
    func registryLinks(for project: Project) -> [(title: String, url: URL)] {
        guard let entry = SettingsModel.entry(for: project, in: registryEntries) else { return [] }
        return MenuModel.openLinks(entry: entry, docsPage: Controller.docsPageURL(portal: portalBase, registryID: entry.id))
    }

    func appendLinks(_ links: [(title: String, url: URL)], to menu: NSMenu) {
        for link in links {
            item(link.title, in: menu, action: #selector(openService(_:)), value: link.url.absoluteString)
        }
    }

    func projectSubmenu(_ status: ProjectStatus) -> NSMenu {
        let project = status.project
        let sub = NSMenu()
        sub.autoenablesItems = false

        if project.archived {
            item("Archived and paused · not started by Switchboard", in: sub)
            return sub
        }

        if project.launcherManaged {
            if role == .client {
                item("Sources and agents stay on Mac Mini", in: sub)
                let isRemoteUp = status.state == .on || status.state == .partial
                if isRemoteUp {
                    item(project.ports.isEmpty ? "● Background task RUNNING on Mac Mini" : "● Remote dev server UP on Mac Mini", in: sub)
                } else {
                    item(project.ports.isEmpty ? "○ Background task STOPPED on Mac Mini" : "○ Remote dev server DOWN on Mac Mini", in: sub)
                }
                if !status.listening.isEmpty {
                    item("● Ports forwarded locally: \(status.listening.map(String.init).joined(separator: ", "))", in: sub)
                } else if !project.ports.isEmpty {
                    item("○ Ports inactive (tunnel closed)", in: sub)
                }
                sub.addItem(.separator())

                item("Actions", in: sub)
                item("Start Remote Work", in: sub, action: #selector(control(_:)), value: ["start", project.key], enabled: MenuModel.remoteStartEnabled(busy: busy != nil, refreshFailed: refreshError != nil))
                item(project.ports.isEmpty ? "Stop Remote Process" : "Stop Remote Dev Server", in: sub, action: #selector(control(_:)), value: ["stop", project.key], enabled: busy == nil && isRemoteUp && refreshError == nil)
                item(project.ports.isEmpty ? "Restart Remote Process" : "Restart Dev Server", in: sub, action: #selector(control(_:)), value: ["restart", project.key], enabled: busy == nil && isRemoteUp && refreshError == nil)
                item("Remote work preserves uncommitted Mini files", in: sub)
            } else {
                if project.ports.isEmpty {
                    item(status.state == .on ? "Background process active" : "Background process stopped", in: sub)
                } else {
                    item("\(status.listening.count)/\(project.ports.count) ports listening · \(project.ports.map(String.init).joined(separator: ", "))", in: sub)
                }
                sub.addItem(.separator())

                item("Actions", in: sub)
                item("Start", in: sub, action: #selector(control(_:)), value: ["start", project.key], enabled: busy == nil && status.state == .off && refreshError == nil)
                item("Stop", in: sub, action: #selector(control(_:)), value: ["stop", project.key], enabled: busy == nil && status.state != .off && refreshError == nil)
                item("Restart", in: sub, action: #selector(control(_:)), value: ["restart", project.key], enabled: busy == nil && status.state != .off && refreshError == nil)
            }
        } else if project.isIdeaDesk || project.isDocsPortal {
            serviceItems(status, in: sub)
        } else {
            if project.key == "workspace-root" {
                item("Workspace meta-repository", in: sub)
            } else {
                item("Repository workspace", in: sub)
            }
        }

        appendGitAndQuality(status: status, to: sub)

        var openItems: [(title: String, action: Selector, value: Any?)] = []
        if project.webPort > 0 && !project.isIdeaDesk && !project.isDocsPortal {
            if role == .client {
                let isRemoteUp = status.state == .on || status.state == .partial
                if isRemoteUp && !status.listening.isEmpty && status.listening.contains(project.webPort) {
                    openItems.append(("Open localhost:\(project.webPort) in Browser", #selector(openWeb(_:)), project.webPort))
                }
            } else if status.listening.contains(project.webPort) {
                openItems.append(("Open localhost:\(project.webPort) in Browser", #selector(openWeb(_:)), project.webPort))
            }
        }
        let links = registryLinks(for: project)
        for link in links {
            openItems.append((link.title, #selector(openService(_:)), link.url.absoluteString))
        }
        if role == .client {
            openItems.append(("Open Mini Project in Cursor", #selector(openRemoteProject(_:)), project.key))
        } else {
            openItems.append(("Reveal in Finder", #selector(revealInFinder(_:)), project.key))
        }
        if project.launcherManaged && role == .host {
            openItems.append(("View Logs", #selector(openLog(_:)), project.key))
        }

        if !openItems.isEmpty {
            sub.addItem(.separator())
            item("Open", in: sub)
            for itemDef in openItems {
                item(itemDef.title, in: sub, action: itemDef.action, value: itemDef.value)
            }
        }

        return sub
    }

    func appendGitAndQuality(status: ProjectStatus, to sub: NSMenu) {
        let project = status.project
        sub.addItem(.separator())
        item(role == .client ? "Air Checkout Git · Remote Quality" : "Git & Quality", in: sub)
        if let git = status.git {
            item("Branch: \(git.branch)", in: sub)
            if git.isClean {
                item("✔ Working tree clean & in sync with origin", in: sub)
            } else {
                if git.dirty > 0 { item("● \(git.dirty) uncommitted change(s)", in: sub) }
                if git.ahead > 0 { item("● \(git.ahead) commit(s) ahead (unpushed)", in: sub) }
                if git.behind > 0 { item("● \(git.behind) commit(s) behind (needs pull)", in: sub) }
                for r in git.repos where r.dirty > 0 || r.ahead > 0 || r.behind > 0 {
                    var notes: [String] = []
                    if r.dirty > 0 { notes.append("\(r.dirty) modified") }
                    if r.ahead > 0 { notes.append("↑\(r.ahead)") }
                    if r.behind > 0 { notes.append("↓\(r.behind)") }
                    item("  › \(r.name): \(notes.joined(separator: ", "))", in: sub)
                }
            }
            item("View Git Details…", in: sub, action: #selector(showProjectGitDetails(_:)), value: project.key)
        } else {
            item("Git status unavailable", in: sub)
        }

        if project.launcherManaged && !project.ports.isEmpty {
            if role == .client {
                item("Run Remote Quick Check (macmini-quick)", in: sub, action: #selector(control(_:)), value: ["quick", project.key], enabled: busy == nil && refreshError == nil)
                item("Run Remote Deploy (macmini-deploy)", in: sub, action: #selector(control(_:)), value: ["deploy", project.key], enabled: busy == nil && refreshError == nil)
            } else {
                item("Run Quick Check (npm run quick)", in: sub, action: #selector(control(_:)), value: ["quick", project.key], enabled: busy == nil && refreshError == nil)
                item("Run Deploy (npm run deploy)", in: sub, action: #selector(control(_:)), value: ["deploy", project.key], enabled: busy == nil && refreshError == nil)
            }
        }
    }

    func projectActionsItem() -> NSMenuItem {
        let actions = NSMenu()
        actions.autoenablesItems = false
        let dirtyProjects = statuses.filter { ($0.git?.dirty ?? 0) > 0 || ($0.git?.ahead ?? 0) > 0 }
        let title: String
        if role == .client {
            title = dirtyProjects.isEmpty ? "Session Actions" : "Session Actions (\(dirtyProjects.count) uncommitted/unpushed)"
            item("Stop All Remote Dev Servers", in: actions, action: #selector(control(_:)), value: ["stop", "all"], enabled: busy == nil && !statuses.isEmpty && refreshError == nil)
            actions.addItem(.separator())
            item("Start All Projects (Heavy · launches all on Mini)", in: actions, action: #selector(control(_:)), value: ["start", "all"], enabled: busy == nil && !statuses.isEmpty && refreshError == nil)
            actions.addItem(.separator())
            item("View Last Result…", in: actions, action: #selector(showLastResult))
            item("Refresh Status Now", in: actions, action: #selector(refreshNow))
        } else {
            title = dirtyProjects.isEmpty ? "Project Actions" : "Project Actions (\(dirtyProjects.count) uncommitted/unpushed)"
            item("Stop All Development Servers", in: actions, action: #selector(control(_:)), value: ["stop", "all"], enabled: busy == nil && !statuses.isEmpty && refreshError == nil)
            actions.addItem(.separator())
            item("Check All Repositories (npm run repos:check)", in: actions, action: #selector(control(_:)), value: ["repos-check", "all"], enabled: busy == nil && refreshError == nil)
            item("Push All Repositories (npm run repos:push)", in: actions, action: #selector(control(_:)), value: ["repos-push", "all"], enabled: busy == nil && refreshError == nil)
            item("Sync All Repositories (npm run repos:sync)", in: actions, action: #selector(control(_:)), value: ["repos-sync", "all"], enabled: busy == nil && refreshError == nil)
            actions.addItem(.separator())
            item("Start All Projects (Heavy · launches all)", in: actions, action: #selector(control(_:)), value: ["start", "all"], enabled: busy == nil && !statuses.isEmpty && refreshError == nil)
            actions.addItem(.separator())
            item("View Last Result…", in: actions, action: #selector(showLastResult))
            item("Refresh Project Status", in: actions, action: #selector(refreshNow))
        }
        let actionGroup = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        actionGroup.submenu = actions
        return actionGroup
    }

    // MARK: Services and system group

    func appendServicesGroup(to menu: NSMenu) {
        item("Services and system", in: menu)
        if role == .client {
            appendClientInfrastructure(to: menu)
        } else {
            appendHostInfrastructure(to: menu)
        }
        for status in statuses where MenuModel.group(of: status.project) == .services {
            let row = NSMenuItem(title: MenuModel.rowTitle(status, role: role), action: nil, keyEquivalent: "")
            row.image = statusImage(status)
            let sub = NSMenu()
            sub.autoenablesItems = false
            serviceItems(status, in: sub)
            row.submenu = sub
            menu.addItem(row)
        }
        menu.addItem(.separator())
        item("Configure Projects…", in: menu, action: #selector(openProjectSettings))
        appendPreferences(to: menu)
    }

    func appendClientInfrastructure(to menu: NSMenu) {
        item("Host: Mac Mini (SSH alias macmini)", in: menu)

        // Remote Infrastructure / Dev Tunnel
        let tunnel = NSMenuItem(title: remoteStatus.devTunnelActive ? "Dev Tunnel · Connected (PID \(remoteStatus.devTunnelPID ?? 0))" : "Dev Tunnel · Inactive", action: nil, keyEquivalent: "")
        tunnel.image = NSImage(systemSymbolName: remoteStatus.devTunnelActive ? "bolt.horizontal.fill" : "bolt.horizontal", accessibilityDescription: "Tunnel")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [remoteStatus.devTunnelActive ? .systemGreen : .secondaryLabelColor]))
        let tunnelSub = NSMenu()
        tunnelSub.autoenablesItems = false
        item(remoteStatus.devTunnelActive ? "Forwards dev ports (5173-5182, 3001-3007) to Mac Mini" : "SSH dev port tunnel is closed", in: tunnelSub)
        tunnelSub.addItem(.separator())
        if remoteStatus.devTunnelActive {
            item("Disconnect Dev Tunnel", in: tunnelSub, action: #selector(control(_:)), value: ["tunnel", "down"], enabled: busy == nil)
            item("Reconnect Dev Tunnel", in: tunnelSub, action: #selector(control(_:)), value: ["tunnel", "reset"], enabled: busy == nil)
            item("Reset & Free Ports", in: tunnelSub, action: #selector(control(_:)), value: ["tunnel", "reset-force"], enabled: busy == nil)
        } else {
            item("Connect Dev Tunnel", in: tunnelSub, action: #selector(control(_:)), value: ["tunnel", "up"], enabled: busy == nil)
            item("Force Connect (Free Local Ports)", in: tunnelSub, action: #selector(control(_:)), value: ["tunnel", "force"], enabled: busy == nil)
        }
        tunnel.submenu = tunnelSub
        menu.addItem(tunnel)

        // Remote Docker Tunnel (Mongo :27018 / Redis :6380)
        let dockerItem = NSMenuItem(title: remoteStatus.dockerTunnelActive ? "Docker Remote · Connected (:27018, :6380)" : "Docker Remote · Inactive", action: nil, keyEquivalent: "")
        dockerItem.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Docker")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [remoteStatus.dockerTunnelActive ? .systemGreen : .secondaryLabelColor]))
        let dockerSub = NSMenu()
        dockerSub.autoenablesItems = false
        item(remoteStatus.dockerTunnelActive ? "Remote Docker socket, Mongo & Redis active" : "Remote Docker tunnel is closed", in: dockerSub)
        dockerSub.addItem(.separator())
        if remoteStatus.dockerTunnelActive {
            item("Disconnect Docker Remote", in: dockerSub, action: #selector(control(_:)), value: ["docker-remote", "down"], enabled: busy == nil)
        } else {
            item("Connect Docker Remote", in: dockerSub, action: #selector(control(_:)), value: ["docker-remote", "up"], enabled: busy == nil)
        }
        dockerItem.submenu = dockerSub
        menu.addItem(dockerItem)
    }

    func appendHostInfrastructure(to menu: NSMenu) {
        // Local Infrastructure (Docker / Mongo / Redis)
        let mongoText = remoteStatus.localMongoActive ? "Mongo :27018 ●" : "Mongo :27018 ○"
        let redisText = remoteStatus.localRedisActive ? "Redis :6380 ●" : "Redis :6380 ○"
        let infraItem = NSMenuItem(title: "Shared Infra · \(mongoText)  \(redisText)", action: nil, keyEquivalent: "")
        infraItem.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Docker")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [(remoteStatus.localMongoActive && remoteStatus.localRedisActive) ? .systemGreen : .systemOrange]))
        let infraSub = NSMenu()
        infraSub.autoenablesItems = false
        item(remoteStatus.localMongoActive ? "● MongoDB 8 replica set active on :27018" : "○ MongoDB inactive on :27018", in: infraSub)
        item(remoteStatus.localRedisActive ? "● Redis 7 active on :6380" : "○ Redis inactive on :6380", in: infraSub)
        infraSub.addItem(.separator())
        item("Start Docker Infra (project-docker up)", in: infraSub, action: #selector(control(_:)), value: ["docker-host", "up"], enabled: busy == nil)
        item("Stop Docker Infra (project-docker down)", in: infraSub, action: #selector(control(_:)), value: ["docker-host", "down"], enabled: busy == nil)
        infraItem.submenu = infraSub
        menu.addItem(infraItem)
    }

    // MARK: Settings window

    @objc func openProjectSettings() {
        switch SettingsModel.openAction(hasWindow: settingsController != nil, saving: registrySaving) {
        case .show:
            settingsController?.show()
            return
        case .busy:
            let alert = NSAlert()
            alert.messageText = "A save is still in progress."
            alert.informativeText = "The previous Configure Projects window is still writing workspace.registry.json. Open it again when the result appears."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        case .create:
            break
        }
        let controller = ProjectSettingsController(
            root: root, appRoot: appRoot, statuses: statuses, entries: registryEntries, prefs: prefs,
            onSaved: { [weak self] in self?.settingsDidSave() },
            onSaving: { [weak self] saving in self?.registrySaving = saving },
            onClosed: { [weak self] in
                self?.settingsController = nil
                // The window's table and text views leave dirty malloc pages behind; hand them
                // back so the resident footprint returns toward its at-rest level.
                malloc_zone_pressure_relief(nil, 0)
            })
        settingsController = controller
        controller.show()
    }

    // Also runs after a partial registry-write failure: whatever reached disk is reloaded.
    func settingsDidSave() {
        prefs = MenuPreferences.load(appRoot: appRoot)
        updateStatusTitle()
        if !tracking { rebuildMenu() }
        let root = self.root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let entries = Registry.entries(root: root)
            let portal = Controller.portalURL(root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.registryEntries = entries
                self.portalBase = portal
                if !self.tracking { self.rebuildMenu() }
            }
        }
    }

    func appendAIUsage(to menu: NSMenu) {
        item(!usageEnabled ? "AI · Paused" : (usageRefreshing ? "AI · Checking…" : "AI"), in: menu)
        for value in usage {
            let row = NSMenuItem(title: value.headline, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            item(value.source, in: sub)
            item(value.detail, in: sub)
            sub.addItem(.separator())
            let formatter = DateFormatter()
            formatter.dateStyle = .medium; formatter.timeStyle = .short
            formatter.locale = Locale(identifier: "en_US")
            if let measured = value.measuredAt {
                item("Updated \(formatter.string(from: measured))\(value.stale ? " · stale" : "")", in: sub)
            }
            if value.windows.isEmpty, let reset = value.nextResetAt {
                item("Resets \(formatter.string(from: reset)) · percentage unavailable", in: sub)
            }
            for window in value.windows {
                item("\(window.name) · \(Int(window.usedPercent.rounded()))% used · \(Int((100 - window.usedPercent).rounded()))% left", in: sub)
                if let reset = window.resetsAt {
                    item(reset > Date() ? "Resets \(formatter.string(from: reset))" : "Reset time passed · waiting for new reading", in: sub)
                }
            }
            if let spend = value.localSpendUSD { item("Recorded this month on this Mac: $\(String(format: "%.2f", spend))", in: sub) }
            sub.addItem(.separator())
            item("Open Usage Dashboard", in: sub, action: #selector(openDashboard(_:)), value: value.dashboard)
            if value.id == "codex" {
                let live = item("Refresh Account Now…", in: sub, action: #selector(refreshCodexAccount), enabled: usageEnabled && !usageRefreshing && (lastAccountRefresh.map { Date().timeIntervalSince($0) >= 60 } ?? true))
                live.toolTip = "Starts a temporary native helper. Combined peak memory can exceed 50 MiB."
            }
            row.submenu = sub
            menu.addItem(row)
        }
        item("Refresh AI Usage", in: menu, action: #selector(refreshUsage), enabled: usageEnabled && !usageRefreshing && (lastUsageRefresh.map { Date().timeIntervalSince($0) >= 60 } ?? true))
        let enabledItem = item("Enable AI Usage", in: menu, action: #selector(toggleUsage))
        enabledItem.state = usageEnabled ? .on : .off
        if providerStatusEnabled {
            appendAIProviderStatus(to: menu)
        }
    }

    func appendAIProviderStatus(to menu: NSMenu) {
        guard providerStatusEnabled else { return }
        menu.addItem(.separator())
        item(providerStatusRefreshing ? "Provider Status · Checking…" : "Provider Status", in: menu)
        if let error = providerStatusError {
            item("Unavailable · \(error)", in: menu)
        } else {
            for provider in providerStatuses {
                let row = NSMenuItem(title: "\(provider.label) · \(provider.stateLabel)", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                item(provider.detail, in: sub)
                if let checked = lastProviderStatusRefresh {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    formatter.locale = Locale(identifier: "en_US")
                    item("Checked \(formatter.string(from: checked))", in: sub)
                }
                row.submenu = sub
                menu.addItem(row)
            }
            if providerStatuses.isEmpty { item("No provider status available yet", in: menu) }
        }
        item("Refresh Provider Status", in: menu, action: #selector(refreshProviderStatus), enabled: providerStatusEnabled && !providerStatusRefreshing && (lastProviderStatusRefresh.map { Date().timeIntervalSince($0) >= 60 } ?? true))
    }

    func appendPreferences(to menu: NSMenu) {
        let modeItem = NSMenuItem(title: "Role: \(role == .client ? "Client (MacBook Air)" : "Host (Mac Mini)")", action: nil, keyEquivalent: "")
        let modeSub = NSMenu()
        modeSub.autoenablesItems = false
        item("Client Mode (MacBook Air / Remote)", in: modeSub, action: #selector(selectRole(_:)), value: "client", enabled: role != .client)
        item("Host Mode (Mac Mini / Local Dev)", in: modeSub, action: #selector(selectRole(_:)), value: "host", enabled: role != .host)
        modeItem.submenu = modeSub
        menu.addItem(modeItem)
        item(MemoryUsage.label, in: menu)

        let providerItem = item("Show Public Provider Status (Statuspages)", in: menu, action: #selector(toggleProviderStatus))
        providerItem.state = providerStatusEnabled ? .on : .off

        let state = loginReport?.modern.rawValue ?? "unknown"
        let loginItem = item("Launch at Login · \(state)", in: menu, action: #selector(toggleLogin),
            enabled: busy == nil && loginReport?.error == nil && loginReport?.legacy.kind == .absent &&
                (loginReport?.modern == .enabled || loginReport?.canRegister == true))
        loginItem.state = loginReport?.enabled == true ? .on : (loginReport?.modern == .requiresApproval ? .mixed : .off)
        item("Login Diagnostic / Migration Plan…", in: menu, action: #selector(showLoginDiagnostic))
        item("Open Login Items Settings…", in: menu, action: #selector(openLoginSettings))
        menu.addItem(.separator())
        item("Quit Switchboard (Keep Projects Running)", in: menu, action: #selector(quit), enabled: busy == nil)
    }

    func serviceItems(_ status: ProjectStatus, in menu: NSMenu) {
        let project = status.project
        item("Managed as a separate service", in: menu)
        if project.isIdeaDesk {
            item("Live Sync disabled · Mini data stays on the Mini", in: menu)
            item("Start IdeaDesk", in: menu, action: #selector(startIdeaDesk), enabled: busy == nil && refreshError == nil)
            let url = Controller.ideaDeskURL(portal: portalBase) ?? (role == .host ? project.webURL : nil)
            if let url = url {
                item("Open IdeaDesk in Browser", in: menu, action: #selector(openService(_:)), value: url.absoluteString)
            }
        } else if project.isDocsPortal {
            item("Start Portal", in: menu, action: #selector(startPortal), enabled: busy == nil && refreshError == nil)
            let url = portalBase ?? (role == .host ? URL(string: "http://localhost:\(project.webPort)/docs/") : nil)
            if let url = url {
                item("Open Private Portal in Browser", in: menu, action: #selector(openService(_:)), value: url.absoluteString)
            }
        } else if role == .host {
            item("Open localhost:\(project.webPort) in Browser", in: menu, action: #selector(openWeb(_:)), value: project.webPort, enabled: status.listening.contains(project.webPort))
        }
    }

    @objc func openService(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "https" || (role == .host && url.host == "localhost") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func revealInFinder(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let status = statuses.first(where: { $0.project.key == key }) else { return }
        let p = status.project
        let url = (p.key == "workspace-root" || p.directory.isEmpty || p.directory == ".")
            ? root
            : root.appendingPathComponent(p.directory)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
    }

    @objc func startPortal() {
        guard busy == nil, statuses.contains(where: { $0.project.isDocsPortal }) else { return }
        guard let url = Controller.portalURL(root: root) ?? (role == .host ? URL(string: "http://localhost:5190/docs/") : nil) else {
            showText("ProjectsDocs", "Configure a private HTTPS origin in ProjectsDocs/docs.config.json (ideaDeskUrl) before starting the portal from this client.")
            return
        }
        let command = Controller.portalStartCommand(role: role)
        runAction(message: "Starting ProjectsDocs…", openAfter: url) {
            let code = try Controller.executeCommand(root: self.root, executable: command.executable, arguments: command.arguments, log: self.actionLog)
            guard code == 0 else { return code }
            // Wait for the portal itself before reporting success and opening it.
            for _ in 0..<5 {
                let response = try Controller.command("/usr/bin/curl", ["--noproxy", "*", "--connect-timeout", "2", "--max-time", "3", "-fsS", "-o", "/dev/null", url.absoluteString], root: self.root)
                if response.status == 0 { return 0 }
                Thread.sleep(forTimeInterval: 0.5)
            }
            let file = try FileHandle(forWritingTo: self.actionLog)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data("ProjectsDocs did not respond at \(url.absoluteString). Check its LaunchAgent and private Tailscale route.\n".utf8))
            return 1
        }
    }

    @objc func startIdeaDesk() {
        guard busy == nil, let project = statuses.first(where: { $0.project.isIdeaDesk })?.project else { return }
        guard let url = Controller.ideaDeskURL(root: root) ?? (role == .host ? project.webURL : nil) else {
            showText("IdeaDesk", "Configure a private HTTPS origin in ProjectsDocs/docs.config.json (ideaDeskUrl) before starting IdeaDesk from this client.")
            return
        }
        let command = Controller.ideaDeskStartCommand(role: role)
        runAction(message: "Starting IdeaDesk…", openAfter: url) {
            let code = try Controller.executeCommand(root: self.root, executable: command.executable, arguments: command.arguments, log: self.actionLog)
            guard code == 0 else { return code }
            let response = try Controller.command("/usr/bin/curl", ["--noproxy", "*", "--connect-timeout", "2", "--max-time", "5", "-fsS", "-o", "/dev/null", url.absoluteString], root: self.root)
            if response.status != 0 {
                let file = try FileHandle(forWritingTo: self.actionLog)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: Data("IdeaDesk is not reachable at its private URL. Check the existing Tailscale route.\n".utf8))
            }
            return response.status
        }
    }

    @objc func selectRole(_ sender: NSMenuItem) {
        guard let newRoleStr = sender.representedObject as? String,
              let newRole = MachineRole(rawValue: newRoleStr) else { return }
        self.role = newRole
        Controller.saveRole(newRole, appRoot: appRoot)
        updateStatusItemAppearance()
        refresh()
        rebuildMenu()
    }

    @objc func openDashboard(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let url = URL(string: text), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func refreshNow() { refresh() }
    @objc func openWeb(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? Int, let url = Project(key: "", directory: "", ports: [], webPort: port).webURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openLog(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if role == .client {
            let proj = statuses.first(where: { $0.project.key == key })?.project.name ?? key
            let syncLog = URL(fileURLWithPath: "/tmp/project-remote-sync-\(proj).log")
            if FileManager.default.fileExists(atPath: syncLog.path) {
                NSWorkspace.shared.open(syncLog)
            } else {
                showText("Live Sync Logs for \(proj)", "No sync logs found at \(syncLog.path). Start working on this project to begin syncing.")
            }
        } else {
            let file = Controller.logDirectory.appendingPathComponent("\(key)-dev.log")
            if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) }
            else { showText("Logs for \(key)", "No logs yet. Start this project to create its log file.") }
        }
    }

    @objc func showProjectGitDetails(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let status = statuses.first(where: { $0.project.key == key }) else { return }
        let p = status.project
        var lines: [String] = []
        lines.append("Project: \(p.name) (\(p.key))")
        lines.append("Directory: \(p.directory)")
        if let git = status.git {
            lines.append("Branch: \(git.branch)")
            lines.append("Uncommitted files (dirty): \(git.dirty)")
            lines.append("Commits ahead of remote (unpushed): \(git.ahead)")
            lines.append("Commits behind remote (unpulled): \(git.behind)")
            lines.append("")
            lines.append("Repositories:")
            for r in git.repos {
                lines.append("• \(r.name) (\(r.path)) [\(r.branch)]")
                lines.append("  Dirty: \(r.dirty), Ahead: \(r.ahead), Behind: \(r.behind)")
                if !r.samples.isEmpty {
                    lines.append("  Modified files sample:")
                    for s in r.samples { lines.append("    \(s)") }
                }
            }
        } else {
            lines.append("Git status unavailable.")
        }
        showText("Git Status · \(p.name)", lines.joined(separator: "\n"))
    }

    @objc func openRemoteProject(_ sender: NSMenuItem) {
        guard role == .client, busy == nil,
              let key = sender.representedObject as? String,
              let project = statuses.first(where: { $0.project.key == key })?.project else { return }
        runAction(message: "Opening Mini project in Cursor…") {
            try Controller.openRemoteProject(root: self.root, project: project, log: self.actionLog)
        }
    }

    @objc func control(_ sender: NSMenuItem) {
        guard busy == nil, let value = sender.representedObject as? [String], value.count >= 2 else { return }
        let action = value[0]
        let target = value[1]
        // Registry services must never reach work/sync with a synthetic registry key.
        let multiRepoActions = ["repos-check", "repos-push", "repos-sync"]
        if !multiRepoActions.contains(action) && target != "all" {
            if statuses.contains(where: { $0.project.key == target && !$0.project.launcherManaged }) && action != "quick" && action != "deploy" { return }
        }

        let execution: (script: String, args: [String], busyMsg: String)
        if role == .client {
            switch action {
            case "start":
                let name = target == "all" ? "all projects" : target
                guard let request = Controller.remoteWorkAction(action: "start", key: target, projects: statuses.map(\.project)) else { return }
                execution = (request.script, request.arguments, "Starting remote work for \(name)…")
            case "stop":
                let name = target == "all" ? "all sessions" : target
                execution = ("project-remote.sh", ["work", "stop", target], "Stopping \(name)…")
            case "restart":
                execution = ("project-remote.sh", ["restart", target], "Restarting dev server for \(target)…")
            case "quick":
                execution = ("project-remote.sh", ["quick", target], "Running remote quick check for \(target) on Mac Mini…")
            case "deploy":
                execution = ("project-remote.sh", ["deploy", target], "Deploying \(target) via Mac Mini…")
            case "tunnel":
                let verb: String
                let args: [String]
                switch target {
                case "force":
                    verb = "Force connecting"
                    args = ["tunnel", "force"]
                case "reset":
                    verb = "Reconnecting"
                    args = ["tunnel", "reset"]
                case "reset-force":
                    verb = "Resetting and freeing ports for"
                    args = ["tunnel", "reset", "--force"]
                case "down":
                    verb = "Disconnecting"
                    args = ["tunnel", "down"]
                default:
                    verb = "Connecting"
                    args = ["tunnel", "up"]
                }
                execution = ("project-remote.sh", args, "\(verb) dev tunnel…")
            case "docker-remote":
                let verb = target == "up" ? "Connecting" : "Disconnecting"
                execution = ("project-docker.sh", ["remote", target], "\(verb) Docker remote tunnel…")
            default:
                return
            }
        } else {
            switch action {
            case "docker-host":
                let verb = target == "up" ? "Starting" : "Stopping"
                execution = ("project-docker.sh", [target], "\(verb) Docker shared infra…")
            case "quick":
                execution = ("project-dev.sh", ["quick", target], "Running quick check for \(target)…")
            case "deploy":
                execution = ("project-deploy.sh", [target], "Deploying \(target)…")
            case "repos-check":
                execution = ("update-master-repos.sh", ["check"], "Checking Git status across all repositories…")
            case "repos-push":
                execution = ("update-master-repos.sh", ["push"], "Pushing current branch across all repositories…")
            case "repos-sync":
                execution = ("update-master-repos.sh", ["sync"], "Synchronizing (commit + pull + push) all repositories…")
            default:
                guard let args = Controller.arguments(action: action, key: target, projects: statuses.map(\.project)) else { return }
                let verb = ["start": "Starting", "stop": "Stopping", "restart": "Restarting"][action] ?? "Processing"
                let name = target == "all" ? "all projects" : target
                execution = ("project-dev.sh", args, "\(verb) \(name)…")
            }
        }

        runAction(message: execution.busyMsg) {
            try Controller.execute(root: self.root, script: execution.script, arguments: execution.args, log: self.actionLog)
        }
    }

    func runAction(message: String, openAfter: URL? = nil, operation: @escaping () throws -> Int32) {
        busy = message
        statusItem.button?.title = " ⏳"
        rebuildMenu()

        worker.async {
            let result = Result { try operation() }
            DispatchQueue.main.async {
                self.busy = nil
                var failure = false
                var failureDetail: String?
                switch result {
                case .success(let code):
                    failure = code != 0
                    self.lastMessage = code == 0 ? "✓ Action completed" : "⚠ Action incomplete · view result"
                case .failure(let error):
                    self.lastMessage = error.localizedDescription
                    failureDetail = error.localizedDescription
                    failure = true
                }
                self.refresh()
                self.rebuildMenu()
                if let detail = failureDetail { self.showText("Action failed", detail) }
                else if failure { self.showLastResult() }
                else if let url = openAfter { NSWorkspace.shared.open(url) }
            }
        }
    }

    @objc func showLoginDiagnostic() {
        showText("Login Diagnostic · Read Only", loginService.migrationPlan())
    }

    @objc func openLoginSettings() {
        // Only this explicit click opens Settings; refresh/denial never does.
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc func toggleLogin() {
        guard busy == nil, let report = loginReport,
              report.legacy.kind == .absent, report.error == nil,
              report.modern == .enabled || report.canRegister else { return }
        let enabled = !report.enabled
        busy = "Updating login registration…"
        rebuildMenu()
        worker.async {
            let result = self.loginService.change(enabled: enabled)
            DispatchQueue.main.async {
                self.busy = nil
                self.loginReport = result
                self.lastMessage = result.error ?? "Login registration: \(result.modern.rawValue)"
                self.rebuildMenu()
                if result.error != nil { self.showText("Login Registration", result.json()) }
            }
        }
    }

    @objc func showLastResult() {
        let text = refreshError ?? ((try? String(contentsOf: actionLog, encoding: .utf8)).map { String($0.suffix(50000)) } ?? (role == .client ? "Switchboard (Client Mode) controls remote development on Mac Mini.\n\n• Use 'Dev Tunnel' to forward all project ports.\n• Use 'Start Remote Work' to reuse Mini files, dev servers and tunnels.\n• Use 'Stop Remote Dev Server' to stop the selected Mini server." : "Choose a project to start or stop. Project status refreshes every minute. AI usage and provider status refresh every five minutes.\n\nStart All respects the launcher’s memory guard and may stop before every project starts.\n\nStop All stops development servers. Databases and other services keep running."))
        showText(role == .client ? "Switchboard (Client) · Result" : "Switchboard · Result", text)
    }

    func showText(_ title: String, _ text: String) {
        let window = resultWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 440), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.string = text
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        window.contentView = scroll
        if resultWindow == nil { window.center() }
        resultWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func quit() { NSApp.terminate(nil) }
}
