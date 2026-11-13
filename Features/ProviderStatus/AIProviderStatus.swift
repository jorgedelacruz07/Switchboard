import Foundation

struct AIProviderStatus: Decodable {
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

enum AIProviderStatusReader {
    static func all(appRoot: URL) throws -> [AIProviderStatus] {
        let componentRoot = appRoot.appendingPathComponent("Features/ProviderStatus", isDirectory: true)
        let result = try Controller.command(
            "/usr/bin/env",
            ["node", "src/cli.js", "status", "--json"],
            root: componentRoot
        )
        guard result.status == 0 else {
            throw NSError(
                domain: "AIProviderStatusReader",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "Provider status check failed." : result.output]
            )
        }
        return try JSONDecoder().decode([AIProviderStatus].self, from: Data(result.output.utf8))
    }
}
