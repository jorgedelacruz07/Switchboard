import Foundation
import CoreFoundation
import CryptoKit
import SQLite3
import Darwin

struct UsageWindow: Codable {
    let name: String
    let usedPercent: Double
    let resetsAt: Date?

    init?(_ name: String, used: Double?, reset: Date? = nil) {
        guard let used = used, used.isFinite, (0...100).contains(used) else { return nil }
        self.name = name
        usedPercent = used
        resetsAt = reset
    }
}

struct AIUsage: Codable {
    let id: String
    let name: String
    let source: String
    let checkedAt: Date
    let measuredAt: Date?
    let windows: [UsageWindow]
    let localSpendUSD: Double?
    let detail: String
    let dashboard: String
    var emptyState: String? = nil
    var nextResetAt: Date? = nil

    var stale: Bool { (measuredAt.map { Date().timeIntervalSince($0) > 900 } ?? false) || windows.contains { $0.resetsAt.map { $0 < Date() } ?? false } }
    var headline: String {
        if let value = windows.max(by: { $0.usedPercent < $1.usedPercent }) {
            return "\(name) · \(Int(value.usedPercent.rounded()))% used\(stale ? " · stale" : "")"
        }
        if let spend = localSpendUSD { return "\(name) · $\(String(format: "%.2f", spend)) local" }
        return "\(name) · \(emptyState ?? "Unavailable")"
    }
}

struct ClaudeCapture: Codable {
    let version: Int
    let accountBinding: String
    let measuredAt: Date
    let windows: [UsageWindow]
}

enum UsageError: Error { case unavailable, timeout, invalidData }

private final class LoopbackSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class JSONReply: @unchecked Sendable {
    private let lock = NSLock()
    private var object: [String: Any]?
    func set(_ value: [String: Any]) { lock.lock(); defer { lock.unlock() }; object = value }
    func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return object }
}

enum UsageReader {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let value = n.doubleValue
        return value.isFinite ? value : nil
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    static func jsonFile(_ file: URL, limit: Int = 262144) throws -> [String: Any] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidData }
        return object
    }

    static func accountBinding() -> String {
        // Keep account identity out of the capture while invalidating account switches.
        let file = home.appendingPathComponent(".claude.json")
        let account = (try? jsonFile(file, limit: 1048576))?["oauthAccount"] as? [String: Any]
        let id = account?["accountUuid"] as? String ?? "unverified-local-session"
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func parseClaude(_ object: [String: Any]) -> [UsageWindow] {
        guard let limits = object["rate_limits"] as? [String: Any] else { return [] }
        return [("five_hour", "Session"), ("seven_day", "Weekly")].compactMap { key, label in
            guard let value = limits[key] as? [String: Any] else { return nil }
            return UsageWindow(label, used: number(value["used_percentage"]), reset: date(value["resets_at"]))
        }
    }

    static func captureClaude(data: Data, destination: URL, binding: String = accountBinding()) throws -> ClaudeCapture {
        guard data.count <= 262144, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidData }
        let capture = ClaudeCapture(version: 1, accountBinding: binding, measuredAt: Date(), windows: parseClaude(object))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(capture).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return capture
    }

    static func claude(appRoot: URL) -> AIUsage {
        let file = appRoot.appendingPathComponent(".local/claude-usage.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        let capture = data.flatMap { $0.count <= 16384 ? try? decoder.decode(ClaudeCapture.self, from: $0) : nil }
        let valid = capture.flatMap { $0.version == 1 && $0.accountBinding == accountBinding() && $0.measuredAt <= Date().addingTimeInterval(60) && $0.windows.allSatisfy { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) } ? $0 : nil }
        return AIUsage(id: "claude", name: "Claude Pro", source: "Claude Code status line", checkedAt: Date(), measuredAt: valid?.measuredAt,
                       windows: valid?.windows ?? [], localSpendUSD: nil,
                       detail: valid?.windows.isEmpty == false ? "Captured during Claude Code activity; may lag web usage." : "Use Claude Code to publish quota data. Open a new session if needed.",
                       dashboard: "https://claude.ai/settings/usage")
    }

    static func parseCodex(_ result: [String: Any]) -> [UsageWindow] {
        guard let limits = result["rateLimits"] as? [String: Any] else { return [] }
        return [("primary", "Session"), ("secondary", "Weekly")].compactMap { key, fallback in
            guard let value = limits[key] as? [String: Any] else { return nil }
            let minutes = number(value["windowDurationMins"])
            let label = minutes == 10080 ? "Weekly" : (minutes == 300 ? "Session" : minutes.map { "\(Int($0)) min window" } ?? fallback)
            return UsageWindow(label, used: number(value["usedPercent"]), reset: date(value["resetsAt"]))
        }
    }

    static func codexRPC(executable: URL, root: URL, timeout: TimeInterval = 12) throws -> [String: Any] {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"]
        process.currentDirectoryURL = root
        process.environment = Controller.environment(root: root)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "mini_bar", "version": "0.2.0"], "capabilities": [:]]])
        var buffer = Data(), bytes = [UInt8](repeating: 0, count: 4096), total = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 200) > 0 else { continue }
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageError.unavailable }
            total += count
            guard total <= 524288 else { throw UsageError.invalidData }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                let id = number(object["id"])
                if id == 1 {
                    guard object["error"] == nil else { throw UsageError.unavailable }
                    try send(["method": "initialized"])
                    // Account inspection only: never create a thread or generate a model turn.
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2 {
                    guard object["error"] == nil, let result = object["result"] as? [String: Any] else { throw UsageError.unavailable }
                    return result
                }
            }
        }
        throw UsageError.timeout
    }

    static func readCodexSession(_ file: URL, accountID: String) throws -> (windows: [UsageWindow], measured: Date)? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 131072) ?? Data()
        guard let newline = head.firstIndex(of: 10),
              let metadata = try JSONSerialization.jsonObject(with: Data(head[..<newline])) as? [String: Any],
              metadata["type"] as? String == "session_meta",
              let owner = metadata["payload"] as? [String: Any], owner["creator_account_id"] as? String == accountID else { return nil }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 262144 ? size - 262144 : 0)
        let tail = try handle.read(upToCount: 262144) ?? Data()
        for line in tail.split(separator: 10).reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  event["type"] as? String == "event_msg", let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count", let rates = payload["rate_limits"] as? [String: Any],
                  rates["limit_id"] as? String == "codex" || rates["limit_id"] == nil,
                  let measured = date(event["timestamp"]), measured <= Date().addingTimeInterval(60) else { continue }
            var normalized: [String: Any] = [:]
            for key in ["primary", "secondary"] {
                if let value = rates[key] as? [String: Any] {
                    normalized[key] = ["usedPercent": value["used_percent"] ?? NSNull(), "windowDurationMins": value["window_minutes"] ?? NSNull(), "resetsAt": value["resets_at"] ?? NSNull()]
                }
            }
            let windows = parseCodex(["rateLimits": normalized])
            if !windows.isEmpty { return (windows, measured) }
        }
        return nil
    }

    static func cachedCodex() -> (windows: [UsageWindow], measured: Date)? {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".codex")
        guard let auth = try? jsonFile(codexHome.appendingPathComponent("auth.json"), limit: 65536), auth["auth_mode"] as? String == "chatgpt",
              let tokens = auth["tokens"] as? [String: Any], let accountID = tokens["account_id"] as? String, !accountID.isEmpty else { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        var directories = Set<String>()
        for zone in [TimeZone.current, TimeZone(secondsFromGMT: 0)!] {
            formatter.timeZone = zone
            for day in 0...2 { directories.insert(formatter.string(from: Date().addingTimeInterval(-Double(day) * 86400))) }
        }
        var files: [(URL, Date)] = []
        for directory in directories {
            let folder = codexHome.appendingPathComponent("sessions/\(directory)")
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
            for file in entries where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((file, modified))
            }
        }
        var latest: (windows: [UsageWindow], measured: Date)?
        for (file, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(12) {
            if let result = try? readCodexSession(file, accountID: accountID), latest == nil || result.measured > latest!.measured { latest = result }
        }
        return latest
    }

    static func codex(root: URL, live: Bool = false) -> AIUsage {
        if !live {
            let cached = cachedCodex()
            return AIUsage(id: "codex", name: "Codex · Plus", source: "Account-matched local Codex quota event", checkedAt: Date(), measuredAt: cached?.measured, windows: cached?.windows ?? [], localSpendUSD: nil,
                           detail: "Updated by Codex activity; may lag other devices. Account refresh is available on demand.", dashboard: "https://chatgpt.com/settings/usage")
        }
        let paths = [home.appendingPathComponent(".local/bin/codex"), URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
        var windows: [UsageWindow] = []
        if let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }), let result = try? codexRPC(executable: executable, root: root) {
            windows = parseCodex(result)
        }
        return AIUsage(id: "codex", name: "Codex · Plus", source: "Codex account rate limits", checkedAt: Date(), measuredAt: windows.isEmpty ? nil : Date(), windows: windows, localSpendUSD: nil,
                       detail: windows.isEmpty ? "Sign in through Codex CLI, then refresh. This does not measure all ChatGPT features." : "Subscription quota for Codex; other ChatGPT features may have separate limits.",
                       dashboard: "https://chatgpt.com/settings/usage")
    }

    static func openCodeSpend(database: URL, since: Date) throws -> Double? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database = db else {
            if let db = db { sqlite3_close(db) }; throw UsageError.unavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        let sql = "SELECT SUM(CAST(json_extract(data,'$.cost') AS REAL)), COUNT(*) FROM message WHERE time_created >= ? AND json_extract(data,'$.role') = 'assistant' AND json_extract(data,'$.providerID') = 'opencode' AND json_type(data,'$.cost') IN ('integer','real') AND json_extract(data,'$.cost') >= 0"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageError.invalidData }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw UsageError.unavailable }
        guard sqlite3_column_int(statement, 1) > 0 else { return nil }
        let total = sqlite3_column_double(statement, 0)
        guard total.isFinite, total >= 0 else { throw UsageError.invalidData }
        return total
    }

    static func opencode() -> AIUsage {
        let start = Calendar.current.dateInterval(of: .month, for: Date())!.start
        let database = home.appendingPathComponent(".local/share/opencode/opencode.db")
        let spend = try? openCodeSpend(database: database, since: start)
        var result = AIUsage(id: "opencode", name: "OpenCode Zen", source: "Local OpenCode database · this month", checkedAt: Date(), measuredAt: spend == nil ? nil : Date(), windows: [], localSpendUSD: spend,
                       detail: "Local recorded spend only; excludes other devices. Account balance is not connected.", dashboard: "https://opencode.ai/console")
        if spend == nil, let count = try? openCodeRecordCount(database: database, since: start), count == 0 {
            result.emptyState = "No local activity this month"
        }
        return result
    }

    static func openCodeRecordCount(database: URL, since: Date) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle = db else {
            if let db = db { sqlite3_close(db) }; throw UsageError.unavailable
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 100)
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM message WHERE time_created >= ? AND json_extract(data,'$.role')='assistant' AND json_extract(data,'$.providerID')='opencode'"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageError.invalidData }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw UsageError.unavailable }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func requestJSON(_ url: URL, body: [String: Any], token: String) throws -> [String: Any] {
        // Requests are confined to the existing IDE's loopback listener. No cookies or TLS bypass.
        guard url.scheme == "http", url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port) else { throw UsageError.invalidData }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 3
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: LoopbackSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let semaphore = DispatchSemaphore(value: 0), result = JSONReply()
        let task = session.dataTask(with: request) { data, response, _ in
            if let response = response as? HTTPURLResponse, response.statusCode == 200, let data = data, data.count <= 524288,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result.set(object)
            }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 4) == .success else { task.cancel(); throw UsageError.timeout }
        guard let object = result.get() else { throw UsageError.unavailable }
        return object
    }

    static func parseGemini(_ object: [String: Any]) -> [UsageWindow] {
        guard let user = object["userStatus"] as? [String: Any], let modelData = user["cascadeModelConfigData"] as? [String: Any],
              let models = modelData["clientModelConfigs"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let label = model["label"] as? String, label.lowercased().contains("gemini"),
                  let quota = model["quotaInfo"] as? [String: Any], let fraction = number(quota["remainingFraction"]), (0...1).contains(fraction) else { return nil }
            return UsageWindow(label, used: (1 - fraction) * 100, reset: date(quota["resetTime"]))
        }
    }

    static func geminiReset(_ object: [String: Any]) -> Date? {
        guard let user = object["userStatus"] as? [String: Any], let data = user["cascadeModelConfigData"] as? [String: Any],
              let models = data["clientModelConfigs"] as? [[String: Any]] else { return nil }
        return models.compactMap { model -> Date? in
            guard (model["label"] as? String)?.lowercased().contains("gemini") == true,
                  let quota = model["quotaInfo"] as? [String: Any] else { return nil }
            return date(quota["resetTime"])
        }.filter { $0 > Date() }.min()
    }

    static func gemini(root: URL) -> AIUsage {
        var windows: [UsageWindow] = []
        var nextReset: Date?
        // Reuse a running IDE. Never launch an IDE, browser, model, or agent for quota checks.
        if let processes = try? Controller.command("/bin/ps", ["-u", String(getuid()), "-o", "pid=,comm="], root: root) {
            let candidates = processes.output.split(separator: "\n").compactMap { line -> Int32? in
                let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard fields.count == 2, fields[1].contains(".app/Contents/Resources/app/extensions/antigravity/bin/language_server_") else { return nil }
                return Int32(fields[0])
            }
            for pid in candidates.prefix(3) {
                guard let command = try? Controller.command("/bin/ps", ["-ww", "-p", String(pid), "-o", "command="], root: root),
                      let regex = try? NSRegularExpression(pattern: "--csrf_token(?:=|\\s+)(\\S+)"),
                      let match = regex.firstMatch(in: command.output, range: NSRange(command.output.startIndex..., in: command.output)),
                      let range = Range(match.range(at: 1), in: command.output),
                      let listeners = try? Controller.command("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], root: root) else { continue }
                let token = String(command.output[range])
                for port in Controller.listeningPorts(listeners.output).sorted().prefix(3) {
                    guard let url = URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus") else { continue }
                    if let object = try? requestJSON(url, body: ["metadata": ["ideName": "antigravity", "extensionName": "antigravity", "locale": "en"]], token: token) {
                        windows = parseGemini(object)
                        nextReset = geminiReset(object)
                        if !windows.isEmpty || nextReset != nil { break }
                    }
                }
                if !windows.isEmpty || nextReset != nil { break }
            }
        }
        var result = AIUsage(id: "gemini", name: "Gemini · Antigravity", source: "Running Antigravity IDE · session models", checkedAt: Date(), measuredAt: windows.isEmpty && nextReset == nil ? nil : Date(), windows: windows, localSpendUSD: nil,
                       detail: nextReset != nil && windows.isEmpty ? "The IDE reports a reset time but omits the remaining percentage." : (windows.isEmpty ? "Open your signed-in Antigravity IDE and refresh. Gemini web limits are separate." : "Quota for the IDE's signed-in account; Gemini web and weekly quotas are separate."),
                       dashboard: "https://gemini.google.com/usage")
        result.nextResetAt = nextReset
        if nextReset != nil && windows.isEmpty { result.emptyState = "Reset time available" }
        return result
    }

    static func all(root: URL, appRoot: URL, liveCodex: Bool = false) -> [AIUsage] {
        [claude(appRoot: appRoot), codex(root: root, live: liveCodex), opencode(), gemini(root: root)]
    }
}
