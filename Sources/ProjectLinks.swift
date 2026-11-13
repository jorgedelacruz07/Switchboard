import Foundation

struct ProjectLinks: Equatable {
    var production: URL?
    var api: URL?
    var repo: URL?
}

struct RegistryEntry: Equatable {
    let id: String
    let name: String
    var links: ProjectLinks
}

enum RegistryError: Error, LocalizedError, Equatable {
    case unreadable, noEntry(String), invalidURL(String), validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "workspace.registry.json is missing, unreadable or malformed; nothing was written."
        case .noEntry(let id): return "workspace.registry.json has no project with id \"\(id)\"; nothing was written."
        case .invalidURL(let text): return "\"\(text)\" is not an https URL with a host and no credentials; nothing was written."
        // The text says what happened to the file (restored, left in place or never written).
        case .validationFailed(let output): return output
        }
    }
}

// View of workspace.registry.json for the menu, plus the one write the settings window needs:
// links.production and links.api of a single project.
enum Registry {
    // Only https URLs with a host and no credentials are accepted; surrounding whitespace is trimmed.
    static func httpsURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    // Keyed by the lowercased folder name of projectRoot, the same match registryServices uses.
    static func entries(root: URL) -> [String: RegistryEntry] {
        let file = root.appendingPathComponent("workspace.registry.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [[String: Any]] else { return [:] }
        var result: [String: RegistryEntry] = [:]
        for entry in projects {
            guard let id = entry["id"] as? String, let name = entry["name"] as? String,
                  let projectRoot = entry["projectRoot"] as? String else { continue }
            let folder = (projectRoot as NSString).lastPathComponent.lowercased()
            guard !folder.isEmpty else { continue }
            let raw = entry["links"] as? [String: Any] ?? [:]
            func link(_ key: String) -> URL? { (raw[key] as? String).flatMap(httpsURL) }
            result[folder] = RegistryEntry(id: id, name: name, links: ProjectLinks(production: link("production"), api: link("api"), repo: link("repo")))
        }
        return result
    }

    // Sets or clears links.production and links.api of the project whose top-level "id" is
    // registryID. nil or blank clears a key; other input must pass httpsURL and is stored as
    // the trimmed original text. The file is edited as text so key order and Prettier
    // formatting survive; bytes outside that project's links block stay identical. The write
    // is atomic (temp file + rename) and the previous bytes come back if validate fails.
    static func writeLinks(root: URL, registryID: String, production: String?, api: String?,
                           validate: (URL) throws -> Void = Registry.runValidate) throws {
        let wanted: [(key: String, value: String?)] = try [("production", production), ("api", api)].map { key, value in
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return (key, nil) }
            guard httpsURL(trimmed) != nil else { throw RegistryError.invalidURL(trimmed) }
            return (key, trimmed)
        }
        let file = root.appendingPathComponent("workspace.registry.json").resolvingSymlinksInPath()
        guard let original = try? Data(contentsOf: file), let oldJSON = jsonObject(original),
              let projects = oldJSON["projects"] as? [Any] else { throw RegistryError.unreadable }
        guard let index = projects.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == registryID }),
              var entry = projects[index] as? [String: Any] else { throw RegistryError.noEntry(registryID) }

        let edited = try editedRegistry(original, entryIndex: index, wanted: wanted)
        guard edited != original else { return }

        // The edit must change nothing but the intended keys of this entry.
        var links = entry["links"] as? [String: Any] ?? [:]
        for (key, value) in wanted {
            if let value { links[key] = value } else { links.removeValue(forKey: key) }
        }
        if links.isEmpty { entry.removeValue(forKey: "links") } else { entry["links"] = links }
        var expectedProjects = projects
        expectedProjects[index] = entry
        var expected = oldJSON
        expected["projects"] = expectedProjects
        guard let newJSON = jsonObject(edited), NSDictionary(dictionary: newJSON).isEqual(to: expected) else {
            throw RegistryError.validationFailed("The text edit would change more than links.production and links.api of \(registryID); nothing was written.")
        }

        // Someone else (an editor, git, another save) may write the file at any time; their
        // bytes are never replaced, neither by this edit nor by its rollback.
        guard (try? Data(contentsOf: file)) == original else {
            throw RegistryError.validationFailed("workspace.registry.json changed while your edit was being prepared; nothing was written.")
        }
        try replaceAtomically(file, with: edited)
        // problem completes "… and the previous file was restored." and detail follows it.
        func restore(_ problem: String, _ detail: String) throws -> Never {
            let tail = detail.isEmpty ? "" : "\n\(detail)"
            guard (try? Data(contentsOf: file)) == edited else {
                throw RegistryError.validationFailed("workspace.registry.json changed while it was being validated; your edit was not rolled back and the new content was left in place.\n\(problem).\(tail)")
            }
            do { try replaceAtomically(file, with: original) } catch {
                throw RegistryError.validationFailed("\(problem) and restoring the previous file also failed: \(error.localizedDescription)\(tail)")
            }
            throw RegistryError.validationFailed("\(problem) and the previous file was restored.\(tail)")
        }
        guard (try? Data(contentsOf: file)) == edited else { try restore("The written registry did not read back as expected", "") }
        do { try validate(root) } catch {
            if let registryError = error as? RegistryError, case .validationFailed(let output) = registryError {
                try restore("Registry validation failed", output)
            }
            try restore("Registry validation failed", error.localizedDescription)
        }
    }

    // Runs the meta-repo validator (no projections are written). Any non-zero exit fails:
    // the validator exits 1 for rule violations and 2 for an unreadable or malformed file.
    static func runValidate(root: URL) throws {
        let result: CommandResult
        do {
            result = try Controller.command("/usr/bin/env", ["node", "workspace-registry.mjs", "--validate"], root: root)
        } catch {
            throw RegistryError.validationFailed("Could not run node workspace-registry.mjs --validate: \(error.localizedDescription)")
        }
        guard result.status == 0 else {
            throw RegistryError.validationFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func encoded(_ text: String) -> [UInt8] {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return [UInt8](data)
    }

    // Returns the registry bytes with the links block of projects[entryIndex] rewritten,
    // inserted as the entry's last key, or removed when it would become empty.
    private static func editedRegistry(_ data: Data, entryIndex: Int, wanted: [(key: String, value: String?)]) throws -> Data {
        let text = JSONText(bytes: [UInt8](data))
        let top = try text.members(ofObjectAt: text.skipSpace(0))
        guard let projects = top.members.last(where: { $0.key == "projects" }) else { throw RegistryError.unreadable }
        let elements = try text.elements(ofArrayAt: projects.valueStart)
        guard entryIndex < elements.count else { throw RegistryError.unreadable }
        let entryOpen = elements[entryIndex]
        let entry = try text.members(ofObjectAt: entryOpen)
        guard let lastMember = entry.members.last else { throw RegistryError.unreadable }

        let memberIndent = text.lineIndent(before: lastMember.keyStart) ?? ""
        let entryIndent = text.lineIndent(before: entryOpen) ?? ""
        let unit = memberIndent.count > entryIndent.count && memberIndent.hasPrefix(entryIndent)
            ? String(memberIndent.dropFirst(entryIndent.count)) : "  "
        func block(_ items: [(key: [UInt8], value: [UInt8])], inner: String, outer: String) -> [UInt8] {
            var out = Array("{\n".utf8)
            for (offset, item) in items.enumerated() {
                out += Array(inner.utf8) + item.key + Array(": ".utf8) + item.value
                out += Array((offset == items.count - 1 ? "\n" : ",\n").utf8)
            }
            return out + Array(outer.utf8) + Array("}".utf8)
        }

        var bytes = text.bytes
        guard let linksIndex = entry.members.lastIndex(where: { $0.key == "links" }) else {
            let items = wanted.compactMap { item in item.value.map { (key: encoded(item.key), value: encoded($0)) } }
            if items.isEmpty { return data }
            let insertion = Array(",\n\(memberIndent)\"links\": ".utf8) + block(items, inner: memberIndent + unit, outer: memberIndent)
            bytes.insert(contentsOf: insertion, at: lastMember.valueEnd)
            return Data(bytes)
        }

        let links = entry.members[linksIndex]
        guard text.byte(links.valueStart) == UInt8(ascii: "{") else { throw RegistryError.unreadable }
        let current = try text.members(ofObjectAt: links.valueStart).members
        let before = current.map { (name: $0.key, key: Array(bytes[$0.keyStart..<$0.keyEnd]), value: Array(bytes[$0.valueStart..<$0.valueEnd])) }
        var items = before
        for (key, value) in wanted {
            let existing = items.firstIndex { $0.name == key }
            switch (existing, value) {
            case (nil, nil): continue
            case let (position?, nil): items.remove(at: position)
            case let (position?, value?): items[position].value = encoded(value)
            case let (nil, value?):
                // Keep the order repo, production, api.
                let position: Int
                if key == "production", let api = items.firstIndex(where: { $0.name == "api" }) { position = api }
                else if key == "api", let production = items.firstIndex(where: { $0.name == "production" }) { position = production + 1 }
                else if let repo = items.firstIndex(where: { $0.name == "repo" }) { position = repo + 1 }
                else { position = items.count }
                items.insert((name: key, key: encoded(key), value: encoded(value)), at: position)
            }
        }
        if items.map({ [$0.key, $0.value] }) == before.map({ [$0.key, $0.value] }) { return data }

        if items.isEmpty {
            // Drop the whole member and exactly one adjacent comma.
            let range: Range<Int>
            if linksIndex > 0 { range = entry.members[linksIndex - 1].valueEnd..<links.valueEnd }
            else if entry.members.count > 1 { range = links.keyStart..<entry.members[1].keyStart }
            else { range = links.keyStart..<links.valueEnd }
            bytes.removeSubrange(range)
        } else {
            let outer = text.lineIndent(before: links.keyStart) ?? memberIndent
            let inner = current.first.flatMap { text.lineIndent(before: $0.keyStart) } ?? outer + unit
            bytes.replaceSubrange(links.valueStart..<links.valueEnd,
                                  with: block(items.map { (key: $0.key, value: $0.value) }, inner: inner, outer: outer))
        }
        return Data(bytes)
    }

    // Writes a sibling temp file and renames it over the target, keeping its permissions.
    private static func replaceAtomically(_ file: URL, with data: Data) throws {
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            if let permissions = try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            }
            guard rename(temp.path, file.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path, NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

// Structural scanner over JSON bytes that JSONSerialization has already accepted. It only
// finds value boundaries; string contents (escaped quotes, braces) are skipped, never parsed.
private struct JSONText {
    struct Member { let key: String; let keyStart: Int; let keyEnd: Int; let valueStart: Int; let valueEnd: Int }
    let bytes: [UInt8]

    func byte(_ index: Int) -> UInt8 { index >= 0 && index < bytes.count ? bytes[index] : 0 }

    func skipSpace(_ index: Int) -> Int {
        var index = index
        while [0x20, 0x09, 0x0A, 0x0D].contains(byte(index)) { index += 1 }
        return index
    }

    // Index just past the closing quote of the string that opens at index.
    func stringEnd(_ index: Int) throws -> Int {
        guard byte(index) == UInt8(ascii: "\"") else { throw RegistryError.unreadable }
        var index = index + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): return index + 1
            default: index += 1
            }
        }
        throw RegistryError.unreadable
    }

    func valueEnd(_ index: Int) throws -> Int {
        switch byte(index) {
        case 0: throw RegistryError.unreadable
        case UInt8(ascii: "\""): return try stringEnd(index)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var cursor = index
            while cursor < bytes.count {
                switch bytes[cursor] {
                case UInt8(ascii: "\""): cursor = try stringEnd(cursor); continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return cursor + 1 }
                default: break
                }
                cursor += 1
            }
            throw RegistryError.unreadable
        default:
            var cursor = index
            while cursor < bytes.count, !Array(",}] \t\n\r".utf8).contains(bytes[cursor]) { cursor += 1 }
            return cursor
        }
    }

    func members(ofObjectAt open: Int) throws -> (members: [Member], close: Int) {
        guard byte(open) == UInt8(ascii: "{") else { throw RegistryError.unreadable }
        var result: [Member] = []
        var index = skipSpace(open + 1)
        if byte(index) == UInt8(ascii: "}") { return (result, index) }
        while true {
            let keyEnd = try stringEnd(index)
            guard let key = (try? JSONSerialization.jsonObject(with: Data(bytes[index..<keyEnd]), options: .fragmentsAllowed)) as? String
            else { throw RegistryError.unreadable }
            var cursor = skipSpace(keyEnd)
            guard byte(cursor) == UInt8(ascii: ":") else { throw RegistryError.unreadable }
            let valueStart = skipSpace(cursor + 1)
            let valueEnd = try self.valueEnd(valueStart)
            result.append(Member(key: key, keyStart: index, keyEnd: keyEnd, valueStart: valueStart, valueEnd: valueEnd))
            cursor = skipSpace(valueEnd)
            switch byte(cursor) {
            case UInt8(ascii: ","): index = skipSpace(cursor + 1)
            case UInt8(ascii: "}"): return (result, cursor)
            default: throw RegistryError.unreadable
            }
        }
    }

    // Start index of each element of the array that opens at index.
    func elements(ofArrayAt open: Int) throws -> [Int] {
        guard byte(open) == UInt8(ascii: "[") else { throw RegistryError.unreadable }
        var result: [Int] = []
        var index = skipSpace(open + 1)
        if byte(index) == UInt8(ascii: "]") { return result }
        while true {
            result.append(index)
            let cursor = skipSpace(try valueEnd(index))
            switch byte(cursor) {
            case UInt8(ascii: ","): index = skipSpace(cursor + 1)
            case UInt8(ascii: "]"): return result
            default: throw RegistryError.unreadable
            }
        }
    }

    // The spaces or tabs between the start of the line and index, or nil if other text precedes it.
    func lineIndent(before index: Int) -> String? {
        var start = index
        while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
        guard start == 0 || bytes[start - 1] == 0x0A else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}

extension Controller {
    // ProjectsDocs publishes one page per registry project under the portal base.
    static func docsPageURL(root: URL, registryID: String) -> URL? {
        docsPageURL(portal: portalURL(root: root), registryID: registryID)
    }

    // Same page from a portal base that the caller already read (the menu reads it once per refresh).
    static func docsPageURL(portal: URL?, registryID: String) -> URL? {
        portal?.appendingPathComponent("projects/\(registryID)/")
    }
}
