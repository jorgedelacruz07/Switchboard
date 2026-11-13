import Foundation

private final class FakeLoginBackend: LoginBackend {
    var current: LoginState = .notRegistered
    var afterRegister: LoginState = .enabled
    var afterUnregister: LoginState = .notRegistered
    var failure: Error?
    var readFailure: Error?
    var registrations = 0
    var unregistrations = 0
    var legacyReads = 0
    func status() throws -> LoginState {
        if let error = readFailure { throw error }; return current
    }
    func legacyStatus(at url: URL) throws -> LoginState { legacyReads += 1; return .requiresApproval }
    func register() throws { registrations += 1; if let error = failure { throw error }; current = afterRegister }
    func unregister() throws { unregistrations += 1; if let error = failure { throw error }; current = afterUnregister }
}

func loginSelfTest() throws {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw NSError(domain: "LoginTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let stableIdentity = LoginIdentity(bundlePath: "/synthetic/build/Switchboard.app", stableBundlePath: "/synthetic/build/Switchboard.app", identifier: LegacyLogin.label)
    try check(stableIdentity.isStable, "Stable path and identifier must match")
    let stagingIdentity = LoginIdentity(bundlePath: "/synthetic/build/stage/Switchboard.app", stableBundlePath: stableIdentity.stableBundlePath, identifier: LegacyLogin.label)
    try check(!stagingIdentity.isStable, "Staged bundle is not the installed app")
    let stagingBackend = SystemLoginBackend(identity: stagingIdentity)
    do { _ = try stagingBackend.status(); throw CocoaError(.validationMissingMandatoryProperty) }
    catch let error as NSError { try check(error.domain == "LoginIdentity", "Staging status refuses before touching real SMAppService") }
    do { try stagingBackend.register(); throw CocoaError(.validationMissingMandatoryProperty) }
    catch let error as NSError { try check(error.domain == "LoginIdentity", "Staging cannot register real login items") }
    try check(!LoginIdentity(bundlePath: stableIdentity.bundlePath, stableBundlePath: stableIdentity.stableBundlePath, identifier: "other").isStable, "Wrong bundle identifier rejected")
    let backend = FakeLoginBackend()
    var legacy = LegacyLogin(kind: .absent, path: "/synthetic/legacy.plist", detail: "fixture")
    let service = LoginService(backend: backend, inspectLegacy: { legacy })
    for state in [LoginState.enabled, .requiresApproval, .notRegistered, .notFound, .unknown] {
        backend.current = state
        let report = service.diagnostic()
        try check(report.modern == state && report.enabled == (state == .enabled), "Typed state/confirmed enabled: \(state)")
        _ = service.migrationPlan()
    }
    try check(backend.registrations == 0 && backend.unregistrations == 0, "Diagnostics and plans never mutate registration")
    backend.current = .notRegistered
    let enabled = service.change(enabled: true)
    try check(enabled.enabled && backend.registrations == 1, "One register followed by confirmed status")
    _ = service.change(enabled: true)
    try check(backend.registrations == 1, "Already enabled is not re-registered")
    let disabled = service.change(enabled: false)
    try check(disabled.modern == .notRegistered && backend.unregistrations == 1, "Unregister verifies status")
    backend.afterRegister = .requiresApproval
    let approval = service.change(enabled: true)
    try check(approval.modern == .requiresApproval && !approval.enabled && approval.exitCode != 0, "Requires approval never claims enabled")
    let calls = backend.registrations
    let repeatApproval = service.change(enabled: true)
    try check(repeatApproval.error != nil && backend.registrations == calls, "No retry on pending approval")
    backend.current = .notFound
    let missing = service.change(enabled: true)
    try check(missing.error != nil && backend.registrations == calls, "Not found refuses registration")
    backend.current = .notRegistered
    backend.failure = NSError(domain: "SyntheticSM", code: 7, userInfo: [NSLocalizedDescriptionKey: "Denied by OS"])
    let denied = service.change(enabled: true)
    try check(denied.error == "Denied by OS" && !denied.enabled && backend.registrations == calls + 1, "Registration error remains explicit; no retry")
    backend.failure = nil
    backend.readFailure = NSError(domain: "SyntheticSM", code: 8, userInfo: [NSLocalizedDescriptionKey: "Status unavailable"])
    let unavailable = service.change(enabled: true)
    try check(unavailable.modern == .unknown && unavailable.error != nil && backend.registrations == calls + 1, "Read error blocks mutation")
    backend.readFailure = nil
    legacy = LegacyLogin(kind: .recognized, path: "/synthetic/own.plist", detail: "fixture")
    let before = backend.registrations
    let mixed = service.change(enabled: true)
    try check(mixed.legacy.authorization == .requiresApproval && mixed.error != nil && backend.registrations == before, "Legacy authorization read; migration gates modern registration")
    try check(service.migrationPlan().contains("no commands executed"), "Migration plan is read-only")
    legacy = LegacyLogin(kind: .unrecognized, path: "/synthetic/other", detail: "preserve")
    let unknown = service.change(enabled: false)
    try check(unknown.error != nil && backend.unregistrations == 1, "Unexpected files cannot be migrated/unregistered automatically")

    backend.current = .enabled
    backend.afterUnregister = .enabled
    legacy = LegacyLogin(kind: .absent, path: "/synthetic/none", detail: "fixture")
    let unconfirmed = service.change(enabled: false)
    try check(unconfirmed.modern == .enabled && unconfirmed.error != nil, "Unregister must confirm notRegistered")
    backend.failure = NSError(domain: "SyntheticSM", code: 9, userInfo: [NSLocalizedDescriptionKey: "Unregister denied"])
    let unregisterError = service.change(enabled: false)
    try check(unregisterError.error == "Unregister denied", "Unregister errors remain explicit")

    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Login Fixture \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let home = temp.appendingPathComponent("home")
    let root = temp.appendingPathComponent("app")
    let expected = root.appendingPathComponent(".local/launchd/\(LegacyLogin.label).plist")
    let link = home.appendingPathComponent("Library/LaunchAgents/\(LegacyLogin.label).plist")
    try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try check(LegacyLogin.inspect(home: home, appRoot: root).kind == .absent, "No file is not a registration")
    let fixture: [String: Any] = ["Label": LegacyLogin.label,
        "ProgramArguments": [root.appendingPathComponent("build/Switchboard.app/Contents/MacOS/Switchboard").path],
        "WorkingDirectory": root.path, "RunAtLoad": true, "LimitLoadToSessionType": "Aqua",
        "StandardOutPath": "/tmp/projects-menu-agent.log", "StandardErrorPath": "/tmp/projects-menu-agent.log"]
    let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .xml, options: 0)
    try data.write(to: expected)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: expected.path)
    try check(LegacyLogin.inspect(home: home, appRoot: root).kind == .recognized, "Recognize only exact own symlink/configuration")
    let preserved = try Data(contentsOf: expected)
    try check(preserved == data, "Inspection preserves plist")
    try Data("invalid".utf8).write(to: expected)
    try check(LegacyLogin.inspect(home: home, appRoot: root).kind == .unrecognized, "Malformed legacy plist preserved")
    try FileManager.default.removeItem(at: link)
    try data.write(to: link)
    try check(LegacyLogin.inspect(home: home, appRoot: root).kind == .unrecognized, "Regular file is preserved for manual review")
    print("Switchboard: \(checks) isolated login checks passed; zero real registration changes.")
}
