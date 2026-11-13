import Foundation

func menuSelfTest() throws {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        checks += 1
        guard condition() else { throw NSError(domain: "MenuTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }
    try check(Registry.httpsURL("https://academydb.com")?.absoluteString == "https://academydb.com", "Accept a plain https URL")
    try check(Registry.httpsURL("  https://Host.Example/x  ")?.absoluteString == "https://Host.Example/x", "Trim whitespace and keep the URL")
    try check(Registry.httpsURL("HTTPS://host.test/")?.host == "host.test", "Scheme check is case-insensitive")
    for bad in ["http://x.test", "javascript:alert(1)", "https://user:pw@h.test", "https://", "", "   ", "https://user@h.test", "ftp://h.test"] {
        try check(Registry.httpsURL(bad) == nil, "Reject \(bad.debugDescription)")
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mini Bar Menu Test \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try check(Registry.entries(root: root).isEmpty, "Missing registry gives no entries")
    let file = root.appendingPathComponent("workspace.registry.json")
    try "{bad".write(to: file, atomically: true, encoding: .utf8)
    try check(Registry.entries(root: root).isEmpty, "Malformed registry gives no entries")
    let json = """
    {"projects":[
      {"id":"a","name":"Alpha","kind":"product","projectRoot":"$HOME/Projects/Folder With Spaces","ports":"Client :5173",
       "links":{"repo":"https://github.com/x/a","production":" https://a.example.test ","api":"http://insecure.test"}},
      {"id":"d","name":"Docs","kind":"system","projectRoot":"$HOME/Projects/Docs","ports":"Portal :5190"},
      {"id":"n","name":"NoRoot","kind":"product"}
    ]}
    """
    try json.write(to: file, atomically: true, encoding: .utf8)
    let entries = Registry.entries(root: root)
    try check(entries.count == 2, "Entries without a projectRoot are skipped")
    let alpha = entries["folder with spaces"]
    try check(alpha?.id == "a" && alpha?.name == "Alpha", "Entry is keyed by the lowercased folder name")
    try check(alpha?.links.production?.absoluteString == "https://a.example.test" && alpha?.links.api == nil && alpha?.links.repo?.absoluteString == "https://github.com/x/a", "Links are trimmed and invalid ones dropped")
    try check(entries["docs"]?.links == ProjectLinks(), "Entry without links has empty links")

    let services = Controller.registryServices(root: root, excluding: [])
    try check(services.first(where: { $0.name == "Docs" })?.isService == true, "System registry entries are services")
    try check(services.first(where: { $0.name == "Docs" })?.kind == "system", "Registry kind is kept on the project")
    let plain = Project(key: "k", directory: "K", ports: [], webPort: 0)
    try check(plain.kind == "product" && !plain.isService, "Default kind is product and not a service")
    try check(Project(key: "ideadesk", directory: "IdeaDesk", ports: [5180], webPort: 5180, launcherManaged: false).isService, "IdeaDesk is a service")
    try check(Project(key: "registry-projectsdocs", directory: "ProjectsDocs", ports: [5190], webPort: 5190, launcherManaged: false).isService, "ProjectsDocs portal is a service")

    try check(Controller.docsPageURL(root: root, registryID: "a") == nil, "No docs page without portal configuration")
    let configDirectory = root.appendingPathComponent("ProjectsDocs")
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["ideaDeskUrl": "https://mini.example.test/"]).write(to: configDirectory.appendingPathComponent("docs.config.json"))
    try check(Controller.docsPageURL(root: root, registryID: "a")?.absoluteString == "https://mini.example.test/docs/projects/a/", "Docs page lives under the portal base")
    // The menu builds links from a portal base read once per refresh; both paths must agree.
    let portal = Controller.portalURL(root: root)
    try check(Controller.docsPageURL(portal: portal, registryID: "a") == Controller.docsPageURL(root: root, registryID: "a"), "Docs page from a stored portal base matches the file-reading path")
    try check(Controller.docsPageURL(portal: nil, registryID: "a") == nil, "No stored portal base, no docs page")
    try check(Controller.ideaDeskURL(portal: portal) == Controller.ideaDeskURL(root: root) && Controller.ideaDeskURL(portal: portal)?.absoluteString == "https://mini.example.test/", "IdeaDesk URL from a stored portal base matches the file-reading path")
    try check(Controller.ideaDeskURL(portal: nil) == nil, "No stored portal base, no IdeaDesk URL")
    try modelSelfTest(check: check)
    try registryWriteSelfTest(check: check)
    try settingsSelfTest(check: check)
    print("Switchboard: \(checks) registry, link, model, registry-write and settings checks passed.")
}

// Prettier-style fixture. Alpha's description holds braces, brackets, escaped quotes and a
// fake `"id": "beta"`; Alpha's repos hold a nested `"id": "beta"` and Beta's repos hold a
// nested `links`, so only a structural match on the top-level entry can pass.
private let registryFixture = #"""
{
  "version": 1,
  "projectsRoot": "$HOME/Projects",
  "projects": [
    {
      "id": "alpha",
      "kind": "product",
      "name": "Alpha",
      "description": "Braces { and } [ ] with \"quoted\" text, a \\ backslash and \"id\": \"beta\" \"links\": {",
      "projectRoot": "$HOME/Projects/Alpha",
      "repos": [
        {
          "id": "beta",
          "path": "$HOME/Projects/Alpha/beta"
        }
      ],
      "links": {
        "repo": "https://github.com/x/alpha"
      },
      "safetyProfile": "general-dev"
    },
    {
      "id": "beta",
      "kind": "product",
      "name": "Beta",
      "projectRoot": "$HOME/Projects/Beta",
      "repos": [
        {
          "id": "workspace",
          "links": {
            "repo": "https://nested.example.test"
          }
        }
      ],
      "docs": {
        "enabled": true
      }
    },
    {
      "id": "gamma",
      "kind": "product",
      "name": "Gamma",
      "links": {
        "repo": "https://github.com/x/gamma",
        "production": "https://gamma.example.test",
        "api": "https://api.gamma.example.test"
      },
      "ideaDesk": {
        "enabled": true
      }
    },
    {
      "id": "delta",
      "name": "Delta",
      "links": {
        "production": "https://delta.example.test",
        "api": "https://api.delta.example.test"
      },
      "planningRunner": "claude"
    },
    {
      "id": "epsilon",
      "name": "Epsilon",
      "links": {
        "api": "https://api.epsilon.example.test"
      }
    }
  ]
}

"""#

private func registryWriteSelfTest(check: (@autoclosure () -> Bool, String) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mini Bar Registry Write Test \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("workspace.registry.json")
    let original = Data(registryFixture.utf8)
    func reset() throws { try original.write(to: file) }
    func current() -> Data { (try? Data(contentsOf: file)) ?? Data() }
    func text() -> String { String(decoding: current(), as: UTF8.self) }
    func thrown(_ body: () throws -> Void) -> Error? { do { try body(); return nil } catch { return error } }
    func noop(_: URL) throws {}
    // The fixture with exactly one occurrence of `old` replaced by `new`; a fragment that is
    // not unique yields a marker that never equals the file.
    func expected(_ old: String, _ new: String) -> String {
        guard registryFixture.components(separatedBy: old).count == 2 else { return "<fragment not unique: \(old)>" }
        return registryFixture.replacingOccurrences(of: old, with: new)
    }
    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 != "workspace.registry.json" }
    }

    // A: links.repo only → production added after repo, nothing else changes.
    try reset()
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let inodeBefore = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
    let alphaOld = "      \"links\": {\n        \"repo\": \"https://github.com/x/alpha\"\n      },\n"
    let alphaNew = "      \"links\": {\n        \"repo\": \"https://github.com/x/alpha\",\n        \"production\": \"https://Alpha.Example/\"\n      },\n"
    try Registry.writeLinks(root: root, registryID: "alpha", production: "  https://Alpha.Example/  ", api: nil, validate: noop)
    try check(text() == expected(alphaOld, alphaNew), "Alpha: only its links block changes; trimmed original text is stored")
    let alphaBlockStart = registryFixture.range(of: alphaOld)!
    try check(text().hasPrefix(String(registryFixture[..<alphaBlockStart.lowerBound])), "Alpha: bytes before the links block are identical")
    try check(text().hasSuffix(String(registryFixture[alphaBlockStart.upperBound...])), "Alpha: bytes after the links block are identical")
    let inodeAfter = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
    try check(inodeBefore != nil && inodeBefore != inodeAfter, "Write replaces the file by rename (new inode)")
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    try check(permissions == 0o600, "Write keeps file permissions")
    try check(leftovers().isEmpty, "Write leaves no temp file: \(leftovers())")
    var oldJSON = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    var projects = oldJSON["projects"] as! [[String: Any]]
    var alphaLinks = projects[0]["links"] as! [String: Any]
    alphaLinks["production"] = "https://Alpha.Example/"
    projects[0]["links"] = alphaLinks
    oldJSON["projects"] = projects
    let newJSON = try JSONSerialization.jsonObject(with: current()) as! [String: Any]
    try check(NSDictionary(dictionary: newJSON).isEqual(to: oldJSON), "Alpha: parsed result equals the original plus the intended change")

    // A: api only → order repo, api.
    try reset()
    try Registry.writeLinks(root: root, registryID: "alpha", production: nil, api: "https://api.alpha.example.test", validate: noop)
    try check(text() == expected(alphaOld, "      \"links\": {\n        \"repo\": \"https://github.com/x/alpha\",\n        \"api\": \"https://api.alpha.example.test\"\n      },\n"), "Alpha: api goes after repo")

    // B: no links → links added as the last key, matching indentation; nested links untouched.
    try reset()
    var validatedText = ""
    try Registry.writeLinks(root: root, registryID: "beta", production: "https://beta.example.test", api: "https://api.beta.example.test", validate: { url in
        validatedText = String(decoding: (try? Data(contentsOf: url.appendingPathComponent("workspace.registry.json"))) ?? Data(), as: UTF8.self)
    })
    let betaOld = "      \"docs\": {\n        \"enabled\": true\n      }\n    },"
    let betaNew = "      \"docs\": {\n        \"enabled\": true\n      },\n      \"links\": {\n        \"production\": \"https://beta.example.test\",\n        \"api\": \"https://api.beta.example.test\"\n      }\n    },"
    try check(text() == expected(betaOld, betaNew), "Beta: links appended as the last key with sibling indentation")
    try check(validatedText == text(), "Validate runs against the root after the new content is in place")
    let betaJSON = try JSONSerialization.jsonObject(with: current()) as! [String: Any]
    let beta = (betaJSON["projects"] as! [[String: Any]])[1]
    try check(beta["links"] as? [String: String] == ["production": "https://beta.example.test", "api": "https://api.beta.example.test"], "Beta: parsed links hold both values")

    // B: clearing both on an entry without links is a no-op.
    try reset()
    try Registry.writeLinks(root: root, registryID: "beta", production: "", api: "   ", validate: { _ in throw RegistryError.validationFailed("must not run") })
    try check(current() == original, "Beta: clearing absent links leaves the file untouched")

    // C: repo + production + api → clearing both keeps repo.
    try reset()
    let gammaOld = "        \"repo\": \"https://github.com/x/gamma\",\n        \"production\": \"https://gamma.example.test\",\n        \"api\": \"https://api.gamma.example.test\"\n      },"
    try Registry.writeLinks(root: root, registryID: "gamma", production: "", api: nil, validate: noop)
    try check(text() == expected(gammaOld, "        \"repo\": \"https://github.com/x/gamma\"\n      },"), "Gamma: clearing both keeps only repo")

    // C: changing production keeps its position and the other values.
    try reset()
    try Registry.writeLinks(root: root, registryID: "gamma", production: "https://gamma2.example.test", api: "https://api.gamma.example.test", validate: noop)
    try check(text() == expected("\"production\": \"https://gamma.example.test\"", "\"production\": \"https://gamma2.example.test\""), "Gamma: production replaced in place")

    // Unchanged values write nothing.
    try reset()
    try Registry.writeLinks(root: root, registryID: "gamma", production: "https://gamma.example.test", api: " https://api.gamma.example.test ", validate: { _ in throw RegistryError.validationFailed("must not run") })
    try check(current() == original, "Gamma: same values leave the file untouched")

    // D: links in the middle would become empty → links removed with its comma.
    try reset()
    try Registry.writeLinks(root: root, registryID: "delta", production: nil, api: nil, validate: noop)
    let deltaOld = "      \"name\": \"Delta\",\n      \"links\": {\n        \"production\": \"https://delta.example.test\",\n        \"api\": \"https://api.delta.example.test\"\n      },\n      \"planningRunner\""
    try check(text() == expected(deltaOld, "      \"name\": \"Delta\",\n      \"planningRunner\""), "Delta: empty links removed")

    // E: links as the last key would become empty → removed with the preceding comma.
    try reset()
    try Registry.writeLinks(root: root, registryID: "epsilon", production: nil, api: "", validate: noop)
    let epsilonOld = "      \"name\": \"Epsilon\",\n      \"links\": {\n        \"api\": \"https://api.epsilon.example.test\"\n      }\n    }"
    try check(text() == expected(epsilonOld, "      \"name\": \"Epsilon\"\n    }"), "Epsilon: trailing empty links removed")

    // E: production added to an api-only block goes before api.
    try reset()
    try Registry.writeLinks(root: root, registryID: "epsilon", production: "https://eps.example.test", api: "https://api.epsilon.example.test", validate: noop)
    try check(text() == expected("        \"api\": \"https://api.epsilon.example.test\"\n      }\n    }", "        \"production\": \"https://eps.example.test\",\n        \"api\": \"https://api.epsilon.example.test\"\n      }\n    }"), "Epsilon: production inserted before api")

    // Rejections leave the file byte-identical.
    try reset()
    for (production, api) in [("http://x", nil), (nil, "javascript:alert(1)"), ("https://user:pw@host.test", nil), ("https://", nil)] as [(String?, String?)] {
        let error = thrown { try Registry.writeLinks(root: root, registryID: "alpha", production: production, api: api, validate: noop) }
        try check(error as? RegistryError == .invalidURL((production ?? api)!), "Reject \(String(describing: production ?? api)) as invalidURL: \(String(describing: error))")
        try check(current() == original, "Invalid URL leaves the file untouched")
    }
    try check(thrown { try Registry.writeLinks(root: root, registryID: "zeta", production: "https://z.test", api: nil, validate: noop) } as? RegistryError == .noEntry("zeta"), "Unknown id throws noEntry")
    try check(current() == original, "Unknown id leaves the file untouched")
    try check(thrown { try Registry.writeLinks(root: root, registryID: "workspace", production: "https://z.test", api: nil, validate: noop) } as? RegistryError == .noEntry("workspace"), "Nested repo ids are not entries")

    // validate failure → original restored byte-for-byte; any error surfaces as validationFailed.
    try reset()
    var error = thrown { try Registry.writeLinks(root: root, registryID: "alpha", production: "https://a.test", api: nil, validate: { _ in throw RegistryError.validationFailed("bad registry") }) }
    try check(error as? RegistryError == .validationFailed("Registry validation failed and the previous file was restored.\nbad registry"), "Validation failure surfaces and says the file was restored: \(String(describing: error))")
    try check(error?.localizedDescription == "Registry validation failed and the previous file was restored.\nbad registry", "Validation failure message is unchanged for the user: \(String(describing: error?.localizedDescription))")
    try check(current() == original, "Validation failure restores the original bytes")

    // A change made by someone else while validate runs is never rolled back.
    try reset()
    let foreign = Data(registryFixture.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2").utf8)
    error = thrown { try Registry.writeLinks(root: root, registryID: "alpha", production: "https://a.test", api: nil, validate: { url in
        try foreign.write(to: url.appendingPathComponent("workspace.registry.json"))
        throw RegistryError.validationFailed("bad registry")
    }) }
    try check(current() == foreign, "A concurrent change during validation survives the failure")
    try check((error as? RegistryError).map { if case .validationFailed(let text) = $0 { return text.contains("changed while it was being validated") && text.contains("not rolled back") && text.contains("bad registry") } else { return false } } == true,
              "A concurrent change during validation is reported: \(String(describing: error?.localizedDescription))")
    try check(error?.localizedDescription.contains("previous file was restored") == false, "A concurrent change is not reported as restored")
    try check(leftovers().isEmpty, "A skipped restore leaves no temp file: \(leftovers())")
    try reset()
    error = thrown { try Registry.writeLinks(root: root, registryID: "beta", production: "https://b.test", api: nil, validate: { _ in throw CocoaError(.fileReadUnknown) }) }
    if case .validationFailed? = error as? RegistryError {} else { try check(false, "Other validate errors become validationFailed: \(String(describing: error))") }
    try check(current() == original, "Other validate errors restore the original bytes")
    try check(leftovers().isEmpty, "Restore leaves no temp file: \(leftovers())")

    // Missing, malformed or unreadable registry → unreadable, file untouched.
    try FileManager.default.removeItem(at: file)
    try check(thrown { try Registry.writeLinks(root: root, registryID: "alpha", production: "https://a.test", api: nil, validate: noop) } as? RegistryError == .unreadable, "Missing registry throws unreadable")
    try check(!FileManager.default.fileExists(atPath: file.path), "Missing registry is not created")
    for bad in ["{bad", "[]", "{\"projects\": 3}", ""] {
        try Data(bad.utf8).write(to: file)
        try check(thrown { try Registry.writeLinks(root: root, registryID: "alpha", production: "https://a.test", api: nil, validate: noop) } as? RegistryError == .unreadable, "Malformed registry \(bad.debugDescription) throws unreadable")
        try check(current() == Data(bad.utf8), "Malformed registry is left untouched")
    }
    try Data(#"{"projects": [{"id": "alpha", "links": "https://x.test"}]}"#.utf8).write(to: file)
    try check(thrown { try Registry.writeLinks(root: root, registryID: "alpha", production: "https://a.test", api: nil, validate: noop) } as? RegistryError == .unreadable, "Non-object links throws unreadable")

    // A symlinked registry stays a symlink; its target is edited.
    try FileManager.default.removeItem(at: file)
    let target = root.appendingPathComponent("real.registry.json")
    try original.write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    try Registry.writeLinks(root: root, registryID: "alpha", production: "https://Alpha.Example/", api: nil, validate: noop)
    try check((try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil, "Symlinked registry stays a symlink")
    let targetText = String(decoding: try Data(contentsOf: target), as: UTF8.self)
    try check(targetText == expected(alphaOld, alphaNew), "Symlink target receives the edit")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.removeItem(at: target)

    // runValidate: any non-zero exit (the real validator exits 2 for a malformed file) fails.
    // Runs a fake workspace-registry.mjs in the temp root, never the real one.
    if (try? Controller.command("/usr/bin/env", ["node", "--version"], root: root))?.status == 0 {
        let script = root.appendingPathComponent("workspace-registry.mjs")
        try Data("console.log('fake validator', process.argv.slice(2).join(' ')); process.exit(2);\n".utf8).write(to: script)
        error = thrown { try Registry.runValidate(root: root) }
        try check(error as? RegistryError == .validationFailed("fake validator --validate"), "runValidate treats exit 2 as failure: \(String(describing: error))")
        try Data("process.exit(process.argv.includes('--validate') ? 0 : 1);\n".utf8).write(to: script)
        try check(thrown { try Registry.runValidate(root: root) } == nil, "runValidate passes on exit 0 with --validate")
    } else {
        print("Switchboard: node not found; runValidate checks skipped.")
    }
}

private func modelSelfTest(check: (@autoclosure () -> Bool, String) throws -> Void) throws {
    func status(_ key: String, _ state: ProjectState, sync: Bool = false, port: Int = 5173, managed: Bool = true, archived: Bool = false, kind: String = "product") -> ProjectStatus {
        let directory = key.prefix(1).uppercased() + key.dropFirst()
        let project = Project(key: key, directory: directory, ports: port == 0 ? [] : [port], webPort: port, launcherManaged: managed, archived: archived, kind: kind)
        return ProjectStatus(project: project, state: state, listening: [], liveSyncAlive: sync, tunnelListening: false)
    }
    let list: [ProjectStatus] = [
        status("alpha", .on, sync: true), status("beta", .on, sync: true), status("gamma", .partial),
        status("off1", .off), status("off2", .off), status("off3", .off), status("off4", .off),
        status("off5", .off), status("off6", .off), status("off7", .off),
        status("old", .archived, archived: true),
        status("ideadesk", .on, port: 5180, managed: false),
        status("registry-projectsdocs", .on, port: 5190, managed: false),
    ]
    let none = MenuPreferences(hidden: [], order: [])
    var count = MenuModel.counter(list, prefs: none)
    try check(count == (3, 10, 0), "Client scenario counts 3 of 10 with no hidden: \(count)")
    count = MenuModel.counter(list, prefs: MenuPreferences(hidden: ["alpha"], order: []))
    try check(count == (2, 9, 1), "Hiding a running project gives 2 of 9 and 1 hidden: \(count)")
    count = MenuModel.counter([], prefs: none)
    try check(count == (0, 0, 0), "Empty list counts 0 of 0")
    count = MenuModel.counter(list, prefs: MenuPreferences(hidden: Set(list.map { $0.project.key }), order: []))
    try check(count.inUse == 0 && count.total == 0 && count.hidden == 10, "All hidden counts 0 of 0 and reports hidden projects: \(count)")
    count = MenuModel.counter([status("srv", .on, kind: "system")], prefs: none)
    try check(count == (0, 0, 0), "System kind is not counted")

    try check(MenuModel.group(of: status("ideadesk", .on).project) == .projects, "IdeaDesk is in projects group")
    try check(MenuModel.group(of: status("docs", .on, kind: "system").project) == .projects, "System kind is in projects group")
    try check(MenuModel.group(of: status("old", .off, archived: true).project) == .archived, "Archived project is archived")
    try check(MenuModel.group(of: status("plain", .on).project) == .projects, "Plain product is a project")

    let abc = ["a", "b", "c", "d"].map { status($0, .off) }
    func keys(_ items: [ProjectStatus]) -> [String] { items.map { $0.project.key } }
    try check(keys(MenuPreferences(hidden: [], order: []).ordered(abc)) == ["a", "b", "c", "d"], "Empty order keeps original order")
    try check(keys(MenuPreferences(hidden: [], order: ["c", "a"]).ordered(abc)) == ["c", "a", "b", "d"], "Listed keys come first, rest keep order")
    try check(keys(MenuPreferences(hidden: [], order: ["zzz", "d", "d"]).ordered(abc)) == ["d", "a", "b", "c"], "Unknown and repeated keys are ignored")
    try check(MenuPreferences(hidden: [], order: ["c"]).ordered([]).isEmpty, "Ordering an empty list is empty")

    let appRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Mini Bar Prefs Test \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: appRoot) }
    try check(MenuPreferences.load(appRoot: appRoot) == MenuPreferences(hidden: [], order: []), "Missing settings load as defaults")
    let settings = appRoot.appendingPathComponent(".local/settings.json")
    try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["role": "client", "workspaceRoot": "/tmp/ws"]).write(to: settings)
    let saved = MenuPreferences(hidden: ["beta", "gamma"], order: ["gamma", "alpha"])
    try saved.save(appRoot: appRoot)
    try check(MenuPreferences.load(appRoot: appRoot) == saved, "Hidden and order round-trip")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    try check(json?["role"] as? String == "client" && json?["workspaceRoot"] as? String == "/tmp/ws", "Save keeps role and workspaceRoot")
    try "{bad".write(to: settings, atomically: true, encoding: .utf8)
    try check(MenuPreferences.load(appRoot: appRoot) == MenuPreferences(hidden: [], order: []), "Malformed settings load as defaults")
    var saveError: Error?
    do { try saved.save(appRoot: appRoot) } catch { saveError = error }
    try check(saveError != nil, "Saving over malformed settings throws instead of dropping role and workspaceRoot")
    try check((try? String(contentsOf: settings, encoding: .utf8)) == "{bad", "Malformed settings are left untouched")
    try Data().write(to: settings)
    try saved.save(appRoot: appRoot)
    try check(MenuPreferences.load(appRoot: appRoot) == saved, "An empty settings file is replaced")

    let synced = status("AcademyDB", .on, sync: true)
    try check(MenuModel.rowTitle(synced, role: .client) == "AcademyDB · Running & Tunneled · :5173", "Client synced row title")
    try check(MenuModel.rowTitle(synced, role: .host) == "AcademyDB · Running · :5173", "Host running row title")
    try check(MenuModel.rowTitle(status("Tool", .off, port: 0), role: .host) == "Tool · Stopped", "No port omits the port segment")
    let resumeProject = Project(key: "jorgedelacruz-resume", directory: "jorgedelacruz-resume", ports: [], webPort: 0)
    let resumeStatus = ProjectStatus(project: resumeProject, state: .on, listening: [])
    try check(MenuModel.rowTitle(resumeStatus, role: .client) == "jorgedelacruz-resume · Running on Mac Mini", "Portless remote task does not claim a tunnel")

    var aheadStatus = status("FinTracking", .on, sync: true)
    aheadStatus.git = ProjectGitStatus(dirty: 0, ahead: 2, behind: 0, branch: "master", repos: [])
    try check(MenuModel.rowTitle(aheadStatus, role: .client) == "FinTracking · Running & Tunneled · :5173 · ↑2", "Row title displays ahead commits")

    var dirtyStatus = status("IdeaDesk", .off, port: 5180)
    dirtyStatus.git = ProjectGitStatus(dirty: 9, ahead: 0, behind: 0, branch: "master", repos: [])
    try check(MenuModel.rowTitle(dirtyStatus, role: .client) == "IdeaDesk · Stopped · :5180 · ±9", "Row title displays dirty files")

    var dirtyAndAhead = status("Portfolio", .on, sync: true)
    dirtyAndAhead.git = ProjectGitStatus(dirty: 26, ahead: 1, behind: 0, branch: "master", repos: [])
    try check(MenuModel.rowTitle(dirtyAndAhead, role: .client) == "Portfolio · Running & Tunneled · :5173 · ±26 ↑1", "Row title displays dirty and ahead")

    try check(MenuModel.stateLabel(status("a", .on, sync: true), role: .client) == "Running & Tunneled", "Client synced and running")
    try check(MenuModel.stateLabel(status("resume", .on, port: 0), role: .client) == "Running on Mac Mini", "Portless task state is not described as tunneled")
    try check(MenuModel.stateLabel(status("a", .off, sync: true), role: .client) == "Stopped", "Legacy sync does not imply a running server")
    try check(MenuModel.stateLabel(status("a", .partial), role: .client) == "Remote Running", "Client partial")
    try check(MenuModel.stateLabel(status("a", .off), role: .client) == "Stopped", "Client stopped")
    try check(MenuModel.stateLabel(status("a", .on, managed: false), role: .client) == "Running", "Client unmanaged uses the state label")
    try check(MenuModel.stateLabel(status("a", .archived, archived: true), role: .client) == "Archived", "Client archived")
    try check(MenuModel.stateLabel(status("a", .partial), role: .host) == "Partial", "Host uses the state label")

    let entry = RegistryEntry(id: "a", name: "Alpha", links: ProjectLinks(production: URL(string: "https://a.example.test/app"), api: URL(string: "https://api.a.example.test"), repo: URL(string: "https://github.com/x/a")))
    let docs = URL(string: "https://mini.example.test/docs/projects/a/")
    let all = MenuModel.openLinks(entry: entry, docsPage: docs)
    try check(all.map { $0.title } == ["Open Production — a.example.test", "Open Production API — api.a.example.test", "Open Repository", "Open in ProjectsDocs"], "Open links in order with hosts")
    try check(all.map { $0.url } == [entry.links.production!, entry.links.api!, entry.links.repo!, docs!], "Open links carry their URLs")
    let partial = MenuModel.openLinks(entry: RegistryEntry(id: "a", name: "Alpha", links: ProjectLinks(repo: URL(string: "https://github.com/x/a"))), docsPage: nil)
    try check(partial.map { $0.title } == ["Open Repository"], "Absent links are omitted")
    try check(MenuModel.openLinks(entry: nil, docsPage: nil).isEmpty, "No entry and no docs page gives no links")
    try check(MenuModel.openLinks(entry: nil, docsPage: docs).map { $0.title } == ["Open in ProjectsDocs"], "Docs page without an entry")
}

private func settingsSelfTest(check: (@autoclosure () -> Bool, String) throws -> Void) throws {
    func status(_ key: String, directory: String, port: Int = 5173, archived: Bool = false, kind: String = "product", managed: Bool = true) -> ProjectStatus {
        let project = Project(key: key, directory: directory, ports: port == 0 ? [] : [port], webPort: port, launcherManaged: managed, archived: archived, kind: kind)
        return ProjectStatus(project: project, state: archived ? .archived : .off, listening: [])
    }
    let entries: [String: RegistryEntry] = [
        "alpha": RegistryEntry(id: "alpha-id", name: "Alpha", links: ProjectLinks(production: URL(string: "https://alpha.example.test"), api: URL(string: "https://api.alpha.example.test"), repo: URL(string: "https://github.com/x/alpha"))),
        "gammafolder": RegistryEntry(id: "gamma", name: "Gamma Portal", links: ProjectLinks()),
        "ideadesk": RegistryEntry(id: "ideadesk", name: "IdeaDesk", links: ProjectLinks()),
    ]
    let statuses = [
        status("alpha", directory: "Alpha"),
        status("beta", directory: "Beta", port: 0),
        status("ideadesk", directory: "IdeaDesk", port: 5180, managed: false),
        status("registry-old", directory: "Old", port: 0, archived: true, kind: "archive"),
        status("registry-gamma", directory: "Gamma Portal", port: 5199, managed: false),
        status("registry-docs", directory: "Docs", port: 5190, kind: "system", managed: false),
    ]
    let prefs = MenuPreferences(hidden: ["alpha", "gone"], order: ["beta", "gone"])
    let rows = SettingsModel.rows(statuses: statuses, entries: entries, prefs: prefs)
    try check(rows.map { $0.key } == ["beta", "alpha", "ideadesk", "registry-gamma", "registry-docs"], "Settings rows: only non-archived projects, in preference order: \(rows.map { $0.key })")
    try check(rows.map { $0.registryID } == [nil, "alpha-id", "ideadesk", "gamma", nil], "Settings rows: folder match, none, and registry id fallback")
    try check(rows.map { $0.hidden } == [false, true, false, false, false] && rows.map { $0.port } == [0, 5173, 5180, 5199, 5190], "Settings rows: hidden flag and read-only port")
    try check(rows[1].production == "https://alpha.example.test" && rows[1].api == "https://api.alpha.example.test" && rows[0].production.isEmpty && rows[3].api.isEmpty, "Settings rows: URL text from the registry entry")
    try check(rows[1].name == "Alpha", "Settings rows: project name")
    try check(SettingsModel.rows(statuses: [], entries: entries, prefs: prefs).isEmpty, "Settings rows: zero projects gives zero rows")

    var edited = rows
    try check(SettingsModel.firstInvalid(edited) == nil, "Valid and empty URLs pass")
    edited[1].production = "  https://Alpha.Example/  "
    edited[3].production = "   "
    try check(SettingsModel.firstInvalid(edited) == nil, "Whitespace and padded https URLs pass")
    edited[0].production = "http://ignored.test"
    try check(SettingsModel.firstInvalid(edited) == nil, "Rows without a registry entry are not validated")
    edited[3].api = "javascript:alert(1)"
    edited[1].api = "https://user:pw@host.test"
    let invalid = SettingsModel.firstInvalid(edited)
    try check(invalid?.project == "Alpha" && invalid?.field == "API URL", "First invalid URL names project and field: \(String(describing: invalid))")
    edited[1].production = "https://"
    try check(SettingsModel.firstInvalid(edited)?.field == "Production URL", "Production is checked before API")

    // Changes are matched by key, so reordering alone changes nothing.
    var moved = rows
    moved.swapAt(0, 3)
    moved[0].hidden = true
    try check(SettingsModel.registryChanges(original: rows, edited: moved).isEmpty, "Reorder and visibility do not touch the registry")
    var changed = rows
    changed[0].production = "https://beta.example.test"
    changed[1].production = " https://alpha.example.test "
    changed[3].api = " https://api.gamma.example.test "
    var changes = SettingsModel.registryChanges(original: rows, edited: changed)
    try check(changes == [RegistryChange(name: "Gamma Portal", registryID: "gamma", production: nil, api: "https://api.gamma.example.test")], "Only rows with an entry and changed trimmed text are written: \(changes)")
    changed[1].api = "  "
    changes = SettingsModel.registryChanges(original: rows, edited: changed)
    try check(changes.first == RegistryChange(name: "Alpha", registryID: "alpha-id", production: "https://alpha.example.test", api: nil), "Clearing a field passes nil, the other field keeps its value: \(changes)")
    try check(changes.count == 2, "Both changed rows are written")

    var reordered = rows
    reordered[0].hidden = true
    reordered[1].hidden = false
    reordered.swapAt(0, 3)
    let next = SettingsModel.preferences(reordered, previous: prefs)
    try check(next.order == ["registry-gamma", "alpha", "ideadesk", "beta", "registry-docs", "gone"], "Order: rows first, unknown keys kept after: \(next.order)")
    try check(next.hidden == ["beta", "gone"], "Hidden: rows decide, unknown keys kept: \(next.hidden)")

    let keys = { (items: [SettingsRow]?) in items?.map { $0.key } }
    try check(keys(SettingsModel.move(rows, index: 1, offset: -1)) == ["alpha", "beta", "ideadesk", "registry-gamma", "registry-docs"], "Move up")
    try check(keys(SettingsModel.move(rows, index: 1, offset: 1)) == ["beta", "ideadesk", "alpha", "registry-gamma", "registry-docs"], "Move down")
    try check(SettingsModel.move(rows, index: 0, offset: -1) == nil && SettingsModel.move(rows, index: 4, offset: 1) == nil, "Moves past the edges are refused")
    try check(SettingsModel.move(rows, index: 7, offset: -1) == nil && SettingsModel.move([], index: 0, offset: 1) == nil, "Moves outside the list are refused")

    // The real folder name with an apostrophe, end to end through the registry file.
    let milenaRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Mini Bar Apostrophe Test \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: milenaRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: milenaRoot) }
    try Data(#"{"projects":[{"id":"milenas-portfolio","name":"Milena's Portfolio","kind":"product","projectRoot":"$HOME/Projects/Milena's Portfolio","links":{"production":"https://milena.example.test"}}]}"#.utf8)
        .write(to: milenaRoot.appendingPathComponent("workspace.registry.json"))
    let milenaEntries = Registry.entries(root: milenaRoot)
    try check(milenaEntries["milena's portfolio"]?.id == "milenas-portfolio", "Apostrophe folder is keyed as milena's portfolio: \(milenaEntries.keys.sorted())")
    let milena = Project(key: "milena", directory: "Milena's Portfolio", ports: [5178], webPort: 5178)
    let milenaEntry = SettingsModel.entry(for: milena, in: milenaEntries)
    try check(milenaEntry?.id == "milenas-portfolio" && milenaEntry?.links.production?.absoluteString == "https://milena.example.test", "Launcher project Milena's Portfolio finds its registry entry")

    // Registry writes: applied in order, stopping at the first failure.
    let one = RegistryChange(name: "One", registryID: "one", production: nil, api: nil)
    let two = RegistryChange(name: "Two", registryID: "two", production: nil, api: nil)
    let three = RegistryChange(name: "Three", registryID: "three", production: nil, api: nil)
    var attempted: [String] = []
    let outcome = RegistryWrites.apply([one, two, three]) { change in
        attempted.append(change.registryID)
        if change.registryID == "two" { throw RegistryError.noEntry("two") }
    }
    try check(attempted == ["one", "two"] && outcome.written == [one] && outcome.failure?.change == two && outcome.failure?.error as? RegistryError == .noEntry("two"), "Registry writes stop at the first failure: \(attempted)")
    let clean = RegistryWrites.apply([one, two]) { _ in }
    try check(clean.written == [one, two] && clean.failure == nil, "Registry writes apply every change")


    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Remote Work Test \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Client controls depend on action availability, never the legacy baton owner.
    let miniBaton = WorkspaceHandoffStatus(version: 1, owner: .host, phase: "ready", target: nil,
        updatedAt: nil, blockers: [], initialOwner: nil, localRole: .client, localOwnsWorkspace: false)
    try check(!miniBaton.canHandOff && MenuModel.remoteStartEnabled(busy: false, refreshFailed: false), "Mini-owned baton still permits remote start")
    try check(!MenuModel.remoteStartEnabled(busy: true, refreshFailed: false), "Busy client cannot start")
    try check(!MenuModel.remoteStartEnabled(busy: false, refreshFailed: true), "Failed catalog cannot start")
    let remoteProject = Project(key: "fintracking", directory: "FinTrackingApp", ports: [5174], webPort: 5174)
    let start = Controller.remoteWorkAction(action: "start", key: remoteProject.key, projects: [remoteProject])
    try check(start?.script == "project-remote.sh" && start?.arguments == ["work", "fintracking"], "Client delegates to existing work alias without sync")
    try check(Controller.remoteWorkAction(action: "align", key: remoteProject.key, projects: [remoteProject]) == nil, "Retired align rejected")
    try check(Controller.remoteWorkAction(action: "start", key: "unknown", projects: [remoteProject]) == nil, "Unknown catalog key rejected")
    try check(Controller.environment(root: root)["NO_OPEN"] == "1", "App launcher suppresses automatic browser opening")
    let fakeLauncher = root.appendingPathComponent("project-remote.sh")
    try "printf '%s\\n' \"$@\" \"$NO_OPEN\"; exit 37\n".write(to: fakeLauncher, atomically: true, encoding: .utf8)
    let remoteLog = root.appendingPathComponent("remote.log")
    let startCode = try Controller.execute(root: root, script: start!.script, arguments: start!.arguments, log: remoteLog)
    try check(startCode == 37, "Launcher failure propagates unchanged")
    let launcherOutput = try String(contentsOf: remoteLog)
    try check(launcherOutput == "work\nfintracking\n1\n", "Only work alias and NO_OPEN reach launcher")

    let tricky = Project(key: "synthetic", directory: "Folder ' \" $(touch injected); literal", ports: [5174], webPort: 5174)
    let remoteCommand = try Controller.remoteDirectoryCommand(project: tricky)
    let fakeHome = root.appendingPathComponent("Home")
    let folder = fakeHome.appendingPathComponent("Projects").appendingPathComponent(tricky.directory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Execute only the synthetic directory resolution; no SSH, editor or service.
    let escapedHome = "'" + fakeHome.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let resolved = try Controller.command("/bin/bash", ["-c", "HOME=" + escapedHome + "; " + remoteCommand], root: root)
    let canonical = try Controller.command("/bin/pwd", ["-P"], root: folder)
    try check(resolved.status == 0 && resolved.output == canonical.output, "Catalog directory quoting preserves the physical path")
    try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path), "Directory metacharacters do not execute")
    let cursor = root.appendingPathComponent("fake cursor")
    try "#!/bin/bash\nprintf '%s\\n' \"$@\"; exit 23\n".write(to: cursor, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cursor.path)
    var capturedSSH: (String, [String])?
    let cursorCode = try Controller.openRemoteProject(root: root, project: tricky, log: remoteLog, cursorExecutable: cursor.path) { executable, arguments in
        capturedSSH = (executable, arguments)
        return CommandResult(status: 0, output: canonical.output)
    }
    try check(capturedSSH?.0 == "/usr/bin/ssh" && capturedSSH?.1.last == remoteCommand, "SSH uses bounded options and quoted catalog directory")
    try check(cursorCode == 23, "Cursor failure propagates unchanged")
    let cursorOutput = try String(contentsOf: remoteLog)
    try check(cursorOutput == "--remote\nssh-remote+macmini\n" + canonical.output, "Cursor receives remote folder as one literal argument")
    let sshCode = try Controller.openRemoteProject(root: root, project: remoteProject, log: remoteLog, cursorExecutable: "/missing") { _, _ in CommandResult(status: 255, output: "SSH unavailable") }
    try check(sshCode == 255, "SSH failure prevents editor execution")
    for badPath in ["relative/path", "/one\n/two"] {
        do { _ = try Controller.cursorArguments(remotePath: badPath); throw NSError(domain: "Test", code: 1) }
        catch let error as NSError { try check(error.domain == "Switchboard", "Malformed remote path rejected") }
    }
    // Saves from different windows run one after another on one serial queue.
    let lock = NSLock()
    var running = 0, overlapped = false
    let group = DispatchGroup()
    for _ in 0..<4 {
        RegistryWrites.queue.async(group: group) {
            lock.lock(); running += 1; if running > 1 { overlapped = true }; lock.unlock()
            Thread.sleep(forTimeInterval: 0.02)
            lock.lock(); running -= 1; lock.unlock()
        }
    }
    try check(group.wait(timeout: .now() + 5) == .success && !overlapped, "Registry saves never overlap")

    // Reopening while a save is still running waits instead of building a stale window.
    try check(SettingsModel.openAction(hasWindow: true, saving: true) == .show, "An open window is brought forward")
    try check(SettingsModel.openAction(hasWindow: true, saving: false) == .show, "An open window is brought forward when idle")
    try check(SettingsModel.openAction(hasWindow: false, saving: true) == .busy, "No new window while a save is in flight")
    try check(SettingsModel.openAction(hasWindow: false, saving: false) == .create, "A new window when idle")
}
