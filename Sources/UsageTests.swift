import Foundation
import SQLite3

func usageSelfTest() throws {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        checks += 1
        guard condition() else { throw NSError(domain: "UsageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }
    let now = Date()
    let c: [String: Any] = ["rate_limits": ["five_hour": ["used_percentage": 0, "resets_at": now.timeIntervalSince1970 + 300], "seven_day": ["used_percentage": 100]]]
    let cw = UsageReader.parseClaude(c)
    try check(cw.count == 2 && cw[0].usedPercent == 0 && cw[1].usedPercent == 100, "Real zero and exhausted Claude quota")
    try check(UsageReader.parseClaude([:]).isEmpty, "Missing quota is not zero")
    try check(UsageWindow("Invalid", used: 101) == nil && UsageWindow("Invalid", used: -1) == nil && UsageWindow("Invalid", used: .nan) == nil, "Reject invalid percentages")
    try check(UsageReader.number(true) == nil, "Reject booleans as quota")
    let windows = UsageReader.parseCodex(["rateLimits": ["primary": ["usedPercent": 42, "windowDurationMins": 300], "secondary": ["usedPercent": 12, "windowDurationMins": 10080]]])
    try check(windows.map(\.name) == ["Session", "Weekly"] && windows[0].usedPercent == 42, "Codex window mapping")
    try check(UsageReader.parseCodex([:]).isEmpty, "Codex missing account data")
    let gemini: [String: Any] = ["userStatus": ["cascadeModelConfigData": ["clientModelConfigs": [
        ["label": "Gemini Pro", "quotaInfo": ["remainingFraction": 0.25, "resetTime": "2026-12-01T12:00:00Z"]],
        ["label": "Claude", "quotaInfo": ["remainingFraction": 0.1]], ["label": "Gemini unavailable"],
        ["label": "Gemini invalid", "quotaInfo": ["remainingFraction": 2]]
    ]]]]
    let gw = UsageReader.parseGemini(gemini)
    try check(gw.count == 1 && gw[0].usedPercent == 75 && gw[0].resetsAt != nil, "Gemini measured quotas only")
    try check(UsageReader.parseGemini([:]).isEmpty, "No invented Gemini allowance")
    let resetOnly: [String: Any] = ["userStatus": ["cascadeModelConfigData": ["clientModelConfigs": [["label": "Gemini", "quotaInfo": ["resetTime": "2099-01-01T00:00:00Z"]]]]]]
    try check(UsageReader.parseGemini(resetOnly).isEmpty && UsageReader.geminiReset(resetOnly) != nil, "Reset-only quota does not invent a percentage")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mini Bar Usage Test \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rollout = root.appendingPathComponent("session.jsonl")
    let metadata: [String: Any] = ["type": "session_meta", "payload": ["creator_account_id": "matching-account", "base_instructions": "private-context"]]
    let event: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now), "payload": ["type": "token_count", "rate_limits": ["limit_id": "codex", "primary": ["used_percent": 24, "window_minutes": 300]]]]
    var jsonl = try JSONSerialization.data(withJSONObject: metadata); jsonl.append(10)
    jsonl.append(try JSONSerialization.data(withJSONObject: event)); jsonl.append(10)
    try jsonl.write(to: rollout)
    let local = try UsageReader.readCodexSession(rollout, accountID: "matching-account")
    try check(local?.windows.first?.usedPercent == 24, "Read bounded local Codex quota with matching account")
    let wrongAccount = try UsageReader.readCodexSession(rollout, accountID: "other-account")
    try check(wrongAccount == nil, "Never mix quota from another Codex account")
    let captureFile = root.appendingPathComponent("capture.json")
    var payload = c
    payload["transcript_path"] = "private-transcript"
    payload["session_id"] = "private-session"
    let capture = try UsageReader.captureClaude(data: JSONSerialization.data(withJSONObject: payload), destination: captureFile, binding: "test-binding")
    let serialized = try String(contentsOf: captureFile, encoding: .utf8)
    try check(capture.windows.count == 2 && !serialized.contains("private-transcript") && !serialized.contains("private-session"), "Capture retains only sanitized quota")
    let attrs = try FileManager.default.attributesOfItem(atPath: captureFile.path)
    try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Capture permissions")
    let item = AIUsage(id: "test", name: "Provider", source: "Fixture", checkedAt: now, measuredAt: now.addingTimeInterval(-1000), windows: cw, localSpendUSD: nil, detail: "", dashboard: "https://example.com")
    try check(item.stale && item.headline.contains("stale"), "Stale snapshot is visible")

    var db: OpaquePointer?
    let dbFile = root.appendingPathComponent("usage.db")
    guard sqlite3_open(dbFile.path, &db) == SQLITE_OK else { throw UsageError.unavailable }
    let sql = "CREATE TABLE message(time_created INTEGER, data TEXT); INSERT INTO message VALUES (2000000000000, '{\"role\":\"assistant\",\"providerID\":\"opencode\",\"cost\":1.25}'), (2000000000000, '{\"role\":\"assistant\",\"providerID\":\"other\",\"cost\":99}'), (2000000000000, '{\"role\":\"user\",\"providerID\":\"opencode\",\"cost\":88}'), (1000, '{\"role\":\"assistant\",\"providerID\":\"opencode\",\"cost\":77}'), (2000000000000, '{\"role\":\"assistant\",\"providerID\":\"opencode\"}');"
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); throw UsageError.invalidData }
    sqlite3_close(db)
    let spend = try UsageReader.openCodeSpend(database: dbFile, since: Date(timeIntervalSince1970: 1000000000))
    try check(spend == 1.25, "Only selected provider, period, roles and known costs")
    let absent = try UsageReader.openCodeSpend(database: dbFile, since: Date(timeIntervalSince1970: 2100000000))
    try check(absent == nil, "Unknown local spend is not zero")
    let count = try UsageReader.openCodeRecordCount(database: dbFile, since: Date(timeIntervalSince1970: 2100000000))
    try check(count == 0, "No local activity is distinct from missing costs")

    let rpc = root.appendingPathComponent("fake-codex")
    let fixture = """
    #!/usr/bin/env python3
    import json, sys
    for line in sys.stdin:
        request = json.loads(line)
        if request.get('id') == 1:
            print(json.dumps({'id':1,'result':{}}), flush=True)
        if request.get('id') == 2:
            assert request['method'] == 'account/rateLimits/read'
            print(json.dumps({'id':2,'result':{'rateLimits':{'primary':{'usedPercent':37}}}}), flush=True)
            break
    """
    try fixture.write(to: rpc, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rpc.path)
    let response = try UsageReader.codexRPC(executable: rpc, root: root, timeout: 3)
    try check(UsageReader.parseCodex(response).first?.usedPercent == 37, "RPC initialization and account-only request")
    try "#!/usr/bin/python3\nimport time\ntime.sleep(30)\n".write(to: rpc, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rpc.path)
    do {
        _ = try UsageReader.codexRPC(executable: rpc, root: root, timeout: 0.3)
        try check(false, "RPC timeout must fail")
    } catch UsageError.timeout { try check(true, "Bounded timeout and child cleanup") }
    try check(MemoryUsage.footprintBytes().map { $0 > 0 } ?? false, "Native footprint measurement")
    print("Mini Bar: \(checks) isolated AI usage checks passed.")
}
