import Foundation
import Darwin
import ServiceManagement

// Apple registration status is not equivalent to a file or symlink existing.
enum LoginState: String, Codable {
    case enabled, requiresApproval, notRegistered, notFound, unknown
}

protocol LoginBackend {
    func status() throws -> LoginState
    func legacyStatus(at url: URL) throws -> LoginState
    func register() throws
    func unregister() throws
}

struct LoginIdentity: Codable {
    let bundlePath: String
    let stableBundlePath: String
    let identifier: String?
    var isStable: Bool {
        bundlePath == stableBundlePath && identifier == LegacyLogin.label
    }
    static func current(appRoot: URL) -> LoginIdentity {
        LoginIdentity(bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            stableBundlePath: appRoot.appendingPathComponent("build/Switchboard.app").resolvingSymlinksInPath().path,
            identifier: Bundle.main.bundleIdentifier)
    }
    func requireStable() throws {
        guard isStable else {
            throw NSError(domain: "LoginIdentity", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "This is not the stable installed Switchboard bundle. Staging status is not installed-app status; registration is unavailable here."])
        }
    }
}

struct SystemLoginBackend: LoginBackend {
    let identity: LoginIdentity
    private func map(_ state: SMAppService.Status) -> LoginState {
        switch state {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    func status() throws -> LoginState { try identity.requireStable(); return map(SMAppService.mainApp.status) }
    func legacyStatus(at url: URL) throws -> LoginState { try identity.requireStable(); return map(SMAppService.statusForLegacyPlist(at: url)) }
    private func mutation(_ action: () throws -> Void) throws {
        try identity.requireStable()
        let lock = URL(fileURLWithPath: identity.stableBundlePath).deletingLastPathComponent().appendingPathComponent(".switchboard-update.lock").path
        let descriptor = Darwin.open(lock, O_CREAT | O_EXCL | O_WRONLY, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw NSError(domain: "LoginUpdateLock", code: Int(errno), userInfo: [NSLocalizedDescriptionKey:
                "An update/registration is in progress or its lock cannot be acquired. No retry was performed."])
        }
        defer { close(descriptor); unlink(lock) }
        try action()
    }
    func register() throws { try mutation { try SMAppService.mainApp.register() } }
    func unregister() throws { try mutation { try SMAppService.mainApp.unregister() } }
}

struct LegacyLogin: Codable {
    enum Kind: String, Codable { case absent, recognized, unrecognized }
    let kind: Kind
    let path: String
    let detail: String
    var authorization: LoginState?

    static let label = "com.jorgedelacruz.projects-menu"
    static func inspect(home: URL, appRoot: URL) -> LegacyLogin {
        let file = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let generated = appRoot.appendingPathComponent(".local/launchd/\(label).plist")
        let fm = FileManager.default
        let link = try? fm.destinationOfSymbolicLink(atPath: file.path)
        guard fm.fileExists(atPath: file.path) || link != nil else {
            return LegacyLogin(kind: .absent, path: file.path, detail: "No legacy plist at the expected path.")
        }
        func unknown(_ message: String) -> LegacyLogin {
            LegacyLogin(kind: .unrecognized, path: file.path, detail: message)
        }
        // Only the exact symlink installed by this repository is eligible for a plan.
        guard link == generated.path else { return unknown("Unexpected regular file or symlink; preserve and review manually.") }
        guard let data = try? Data(contentsOf: generated),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return unknown("Expected symlink is broken or its plist cannot be read.")
        }
        let expected: [String: Any] = [
            "Label": label,
            "ProgramArguments": [appRoot.appendingPathComponent("build/Switchboard.app/Contents/MacOS/Switchboard").path],
            "WorkingDirectory": appRoot.path,
            "RunAtLoad": true, "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": "/tmp/projects-menu-agent.log",
            "StandardErrorPath": "/tmp/projects-menu-agent.log"
        ]
        guard NSDictionary(dictionary: info).isEqual(to: expected) else {
            return unknown("Legacy plist differs from the exact expected configuration; preserve and review manually.")
        }
        return LegacyLogin(kind: .recognized, path: file.path,
            detail: "Migration required. Preserve this symlink and its generated plist; no migration has run.")
    }
}

struct LoginDiagnostic: Codable {
    var modern: LoginState = .unknown
    var legacy: LegacyLogin
    var error: String?
    var identity: LoginIdentity?
    var enabled: Bool { modern == .enabled && error == nil }
    var canRegister: Bool { error == nil && legacy.kind == .absent && modern == .notRegistered }
    var exitCode: Int32 { error == nil ? 0 : 1 }
    func json() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{\"error\":\"Could not encode login diagnostic\"}"
    }
}

struct LoginService {
    let backend: LoginBackend
    let inspectLegacy: () -> LegacyLogin
    var identity: LoginIdentity? = nil

    static func live(appRoot: URL) -> LoginService {
        let identity = LoginIdentity.current(appRoot: appRoot)
        return LoginService(backend: SystemLoginBackend(identity: identity), inspectLegacy: {
            LegacyLogin.inspect(home: FileManager.default.homeDirectoryForCurrentUser, appRoot: appRoot)
        }, identity: identity)
    }

    // Refresh/status/plan only read; never register, unregister or open Settings.
    func diagnostic() -> LoginDiagnostic {
        var report = LoginDiagnostic(legacy: inspectLegacy(), identity: identity)
        do {
            report.modern = try backend.status()
            if report.legacy.kind == .recognized {
                report.legacy.authorization = try backend.legacyStatus(at: URL(fileURLWithPath: report.legacy.path))
            }
        } catch { report.error = error.localizedDescription }
        return report
    }

    // One explicit action, one API call, then independently read back the state.
    func change(enabled: Bool) -> LoginDiagnostic {
        var report = diagnostic()
        guard report.error == nil else { return report }
        guard report.legacy.kind == .absent else {
            report.error = "Legacy login configuration is present; inspect migration-plan before changing modern registration. Files were preserved."
            return report
        }
        if enabled && report.modern == .enabled { return report }
        if !enabled && report.modern == .notRegistered { return report }
        guard enabled ? report.modern == .notRegistered : report.modern == .enabled || report.modern == .requiresApproval else {
            report.error = "Registration state is \(report.modern.rawValue). Review the diagnostic; no retry or Settings change was performed."
            return report
        }
        do {
            if enabled { try backend.register() } else { try backend.unregister() }
        } catch {
            var failed = diagnostic(); failed.error = error.localizedDescription
            return failed
        }
        report = diagnostic()
        if enabled ? report.modern != .enabled : report.modern != .notRegistered {
            report.error = "Requested state not confirmed: \(report.modern.rawValue). Preserve macOS consent; no automatic retry."
        }
        return report
    }

    func migrationPlan() -> String {
        let report = diagnostic()
        let consentGuidance = """

        If register returns requiresApproval, leave the pending registration intact while
        Jorge decides in Login Items. Do not auto-unregister, retry or roll back while waiting.
        requiresApproval can also mean consent was revoked: inspect Login Items and stop on
        ambiguity. Keep the app available only through normal app launch; do not claim login
        is enabled. Rollback requires a separate explicit decision and fresh identity-verified
        service state. Stop on notFound, unknown or any error. Only if cancellation is chosen
        and appropriate for the confirmed state, unregister once and verify notRegistered;
        if already notRegistered, skip unregister. No automatic rollback during consent wait.
        """
        guard report.legacy.kind == .recognized else {
            return report.json() + "\nNo automatic migration. Unknown files must remain untouched; absent files need no legacy migration.\n" + consentGuidance
        }
        return report.json() + """

        Read-only migration plan (no commands executed):
        After independent review and controlled rollout approval, record the exact legacy label,
        plist, symlink and installed bundle; preserve backups. Boot out only this user's exact
        existing legacy job, then move its recognized symlink outside Library/LaunchAgents
        without deleting or changing the generated plist. If bootout fails, stop.
        Install the reviewed bundle at the same stable identity/path. Run login status, then
        login register explicitly from that bundle. Only a confirmed enabled state is success.
        After a separate rollback decision and confirmed notRegistered state, review restoration
        of the prior bundle, preserved symlink and unchanged legacy plist under operator review.
        Never reset BTM/trust, alter identifiers, bypass signing checks or delete user files.
        """ + "\n" + consentGuidance
    }
}
