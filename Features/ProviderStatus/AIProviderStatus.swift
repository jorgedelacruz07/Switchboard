import Foundation

struct AIProviderStatus: Decodable, Equatable {
    let id: String
    let label: String
    let observed: String
    let detail: String

    var stateLabel: String {
        switch observed {
        case "ok": return "Operational"
        case "degraded": return "Degraded"
        case "down": return "Outage"
        default: return "Unknown"
        }
    }
}

enum ProviderProbeError: Error, LocalizedError {
    case invalidResponse(String)
    case httpStatus(String, Int)
    case missingComponents(String)
    case unknownStatus(String)
    case staleData(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail),
             .missingComponents(let detail),
             .unknownStatus(let detail),
             .staleData(let detail):
            return detail
        case .httpStatus(let url, let code):
            return "\(url) -> HTTP \(code)"
        }
    }
}

private final class FetchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<(Int, Data), Error>?
    func set(_ result: Result<(Int, Data), Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<(Int, Data), Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

// Native port of src/sources.js so the app needs no Node child process. Both
// implementations must agree on test/fixtures/parity.json (Node and Swift tests).
enum AIProviderStatusReader {
    private static let rank = ["ok": 0, "degraded": 1, "down": 2]
    private static let componentMap = [
        "operational": "ok",
        "under_maintenance": "ok",
        "degraded_performance": "degraded",
        "partial_outage": "degraded",
        "major_outage": "down",
    ]
    private static let openCodeMap = [
        "operational": "ok",
        "degraded": "degraded",
        "down": "down",
        "outage": "down",
        "major_outage": "down",
    ]

    private static func worst(_ a: String, _ b: String) -> String {
        (rank[b] ?? 0) > (rank[a] ?? 0) ? b : a
    }

    static func fromStatuspage(_ data: Data, relevant: [String]) throws -> (observed: String, detail: String) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let components = obj["components"] as? [[String: Any]] else {
            throw ProviderProbeError.invalidResponse("Unexpected Statuspage payload")
        }
        let picked = components.filter { ($0["name"] as? String).map(relevant.contains) ?? false }
        guard !picked.isEmpty else {
            throw ProviderProbeError.missingComponents("Expected components missing from statuspage")
        }
        var status = "ok"
        var bad: [String] = []
        for component in picked {
            guard let name = component["name"] as? String,
                  let raw = component["status"] as? String,
                  let mapped = componentMap[raw] else {
                let raw = component["status"] as? String ?? "nil"
                throw ProviderProbeError.unknownStatus("Unknown component status: \(raw)")
            }
            status = worst(status, mapped)
            if mapped != "ok" { bad.append("\(name): \(raw)") }
        }
        return (status, bad.isEmpty ? "Key components operational" : bad.joined(separator: "; "))
    }

    static func fromGoogleIncidents(_ data: Data) throws -> (observed: String, detail: String) {
        guard let incidents = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ProviderProbeError.invalidResponse("Unexpected Google incidents payload")
        }
        let active = incidents.filter { incident in
            if let end = incident["end"], !(end is NSNull) {
                if let str = end as? String, !str.isEmpty { return false }
            }
            var parts: [String] = []
            if let service = incident["service_name"] as? String { parts.append(service) }
            if let affected = incident["affected_products"] as? [[String: Any]] {
                for product in affected {
                    if let title = product["title"] as? String { parts.append(title) }
                }
            }
            let text = parts.joined(separator: " ").lowercased()
            return text.contains("gemini") || text.contains("vertex ai") || text.contains("antigravity")
        }
        if active.isEmpty {
            return ("ok", "No active Gemini/Vertex AI incidents (approx.)")
        }
        let down = active.contains { ($0["status_impact"] as? String) == "SERVICE_OUTAGE" }
        let details = active.compactMap { $0["external_desc"] as? String }
        return (down ? "down" : "degraded", details.isEmpty ? "Active Gemini/Vertex AI incident" : details.joined(separator: "; "))
    }

    static func fromOpenCodeStatus(_ data: Data) throws -> (observed: String, detail: String) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderProbeError.invalidResponse("Unexpected OpenCode payload")
        }
        if obj["stale"] as? Bool == true {
            throw ProviderProbeError.staleData("status.opencode.ai marked its data stale")
        }
        guard let rawStatus = obj["status"] as? String, let status = openCodeMap[rawStatus] else {
            let raw = obj["status"] as? String ?? "nil"
            throw ProviderProbeError.unknownStatus("Unknown OpenCode status: \(raw)")
        }
        let components = obj["components"] as? [[String: Any]] ?? []
        let bad = components.compactMap { component -> String? in
            guard let compStatus = component["status"] as? String, compStatus != "operational",
                  let service = component["service"] as? String else { return nil }
            let reason = component["reason"] as? String ?? "unknown"
            return "\(service): \(compStatus) (\(reason))"
        }
        return (status, bad.isEmpty ? "Services operational" : bad.joined(separator: "; "))
    }

    private static func fetchData(_ urlString: String, session: URLSession) throws -> (statusCode: Int, data: Data) {
        guard let url = URL(string: urlString) else {
            throw ProviderProbeError.invalidResponse("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.setValue("switchboard", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        let box = FetchResultBox()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                box.set(.failure(error))
            } else if let http = response as? HTTPURLResponse {
                box.set(.success((http.statusCode, data ?? Data())))
            } else {
                box.set(.failure(ProviderProbeError.invalidResponse("Non-HTTP response")))
            }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 11) == .success else {
            task.cancel()
            throw ProviderProbeError.invalidResponse("Timeout fetching \(urlString)")
        }
        guard let result = box.get() else { throw ProviderProbeError.invalidResponse("No response from \(urlString)") }
        return try result.get()
    }

    private static func fetchJSON(_ urlString: String, session: URLSession) throws -> Data {
        let (code, data) = try fetchData(urlString, session: session)
        guard (200...299).contains(code) else {
            throw ProviderProbeError.httpStatus(urlString, code)
        }
        guard data.count <= 2_097_152 else {
            throw ProviderProbeError.invalidResponse("Response too large from \(urlString)")
        }
        return data
    }

    static func all(appRoot: URL) throws -> [AIProviderStatus] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let specs: [(id: String, label: String, probe: () throws -> (observed: String, detail: String))] = [
            ("claude", "Claude", {
                let data = try fetchJSON("https://status.claude.com/api/v2/summary.json", session: session)
                return try fromStatuspage(data, relevant: ["claude.ai", "Claude API (api.anthropic.com)", "Claude Code"])
            }),
            ("openai", "GPT", {
                let data = try fetchJSON("https://status.openai.com/api/v2/summary.json", session: session)
                return try fromStatuspage(data, relevant: ["Chat Completions", "Responses", "Conversations", "Login", "Codex in ChatGPT Desktop"])
            }),
            ("antigravity", "Antigravity", {
                let data = try fetchJSON("https://status.cloud.google.com/incidents.json", session: session)
                return try fromGoogleIncidents(data)
            }),
            ("opencode", "OpenCode", {
                let data = try fetchJSON("https://status.opencode.ai/api/status", session: session)
                let parsed = try fromOpenCodeStatus(data)
                // Real probe: the Zen model catalog must answer (one request).
                let zenCode = (try? fetchData("https://opencode.ai/zen/v1/models", session: session))?.statusCode
                if let zenCode, (200...299).contains(zenCode) { return parsed }
                return ("down", "Zen /models unavailable (\(zenCode.map(String.init) ?? "network error"))")
            }),
        ]

        var results = Array<AIProviderStatus?>(repeating: nil, count: specs.count)
        let lock = NSLock()
        let group = DispatchGroup()
        for (index, spec) in specs.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let item: AIProviderStatus
                do {
                    let obs = try spec.probe()
                    item = AIProviderStatus(id: spec.id, label: spec.label, observed: obs.observed, detail: obs.detail)
                } catch {
                    item = AIProviderStatus(id: spec.id, label: spec.label, observed: "unknown", detail: error.localizedDescription)
                }
                lock.lock()
                results[index] = item
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return results.compactMap { $0 }
    }
}
