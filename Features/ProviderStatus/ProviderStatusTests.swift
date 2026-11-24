import Foundation

// Runs the shared parity fixture (also used by the Node tests) against the native parsers.
func providerStatusSelfTest(fixture: URL) throws {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        checks += 1
        guard condition() else { throw NSError(domain: "ProviderStatusTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }
    let data = try Data(contentsOf: fixture)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cases = root["cases"] as? [[String: Any]], !cases.isEmpty else {
        throw NSError(domain: "ProviderStatusTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Parity fixture unreadable"])
    }
    for item in cases {
        let name = item["name"] as? String ?? "unnamed"
        let expect = item["expect"] as? String ?? ""
        let input = try JSONSerialization.data(withJSONObject: item["input"] ?? NSNull(), options: [.fragmentsAllowed])
        let observed: String
        do {
            switch item["parser"] as? String {
            case "statuspage": observed = try AIProviderStatusReader.fromStatuspage(input, relevant: item["relevant"] as? [String] ?? []).observed
            case "google": observed = try AIProviderStatusReader.fromGoogleIncidents(input).observed
            case "opencode": observed = try AIProviderStatusReader.fromOpenCodeStatus(input).observed
            default: observed = "unsupported parser"
            }
        } catch {
            observed = "error"
        }
        try check(observed == expect, "Provider parity: \(name) expected \(expect), got \(observed)")
    }
    print("Switchboard: provider status parity checks passed (\(checks)); no network used.")
}
