import Foundation

func refreshSelfTest() throws {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        checks += 1
        guard condition() else { throw NSError(domain: "RefreshTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }
    let now = Date()
    // Git runs on its own five-minute cadence, never on the one-minute tick.
    try check(RefreshPolicy.gitRefreshInterval == 300, "Git cadence is five minutes")
    try check(RefreshPolicy.shouldRefreshGit(lastGitRefresh: nil, force: false, fromMenuOpen: false, now: now), "First Git refresh runs")
    try check(!RefreshPolicy.shouldRefreshGit(lastGitRefresh: now.addingTimeInterval(-299), force: false, fromMenuOpen: false, now: now), "Timer waits five minutes")
    try check(RefreshPolicy.shouldRefreshGit(lastGitRefresh: now.addingTimeInterval(-300), force: false, fromMenuOpen: false, now: now), "Timer refreshes after five minutes")
    try check(!RefreshPolicy.shouldRefreshGit(lastGitRefresh: now.addingTimeInterval(-59), force: false, fromMenuOpen: true, now: now), "Menu open respects its Git cooldown")
    try check(RefreshPolicy.shouldRefreshGit(lastGitRefresh: now.addingTimeInterval(-60), force: false, fromMenuOpen: true, now: now), "Menu open refreshes stale Git")
    try check(RefreshPolicy.shouldRefreshGit(lastGitRefresh: now, force: true, fromMenuOpen: false, now: now), "Explicit refresh forces Git")
    try check(!RefreshPolicy.shouldRunMenuOpenRefresh(lastSnapshot: now.addingTimeInterval(-5), now: now), "Rapid menu opens reuse the snapshot")
    try check(RefreshPolicy.shouldRunMenuOpenRefresh(lastSnapshot: now.addingTimeInterval(-15), now: now), "Menu open refreshes an older snapshot")

    // A cached Git map is re-applied without a new snapshot.
    let project = Project(key: "registry-demo", directory: "Demo", ports: [], webPort: 0, launcherManaged: false)
    let git = ProjectGitStatus(dirty: 2, ahead: 1, behind: 0, branch: "main", repos: [])
    let applied = Controller.applying(["demo": git], to: [ProjectStatus(project: project, state: .off, listening: [])])
    try check(applied.first?.git?.dirty == 2, "Git map keyed by registry id applies")
    try check(Controller.applying([:], to: applied).first?.git == nil, "An empty map clears stale Git data")

    // Every spawned command is bounded.
    let root = FileManager.default.temporaryDirectory
    let started = Date()
    var timedOut = false
    do { _ = try Controller.command("/bin/sleep", ["5"], root: root, timeout: 0.3) } catch ControllerError.timedOut { timedOut = true }
    try check(timedOut && Date().timeIntervalSince(started) < 3, "Hung command is stopped at its timeout")
    let fast = try Controller.command("/bin/echo", ["ok"], root: root, timeout: 5)
    try check(fast.status == 0 && fast.output == "ok\n", "Fast command keeps output and status")
    let log = root.appendingPathComponent("switchboard-refresh-test-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: log) }
    var actionTimedOut = false
    do { _ = try Controller.executeCommand(root: root, executable: "/bin/sleep", arguments: ["5"], log: log, timeout: 0.3) } catch ControllerError.timedOut { actionTimedOut = true }
    let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    try check(actionTimedOut && logText.contains("without completion"), "Hung action is stopped and logged")
    print("Switchboard: refresh cadence and command timeout checks passed (\(checks)).")
}
