import Foundation

/// Every provider URL, header and User-Agent Motas asks CLIProxyAPI to call
/// through `POST /v0/management/api-call`. The proxy replaces `$TOKEN$` with
/// the account's own token. Nothing else hard-codes these, and a `Call` can
/// only be made here.
enum UpstreamClients {
    struct Call: Sendable, Hashable {
        let method: String
        let url: String
        let header: [String: String]
        let body: String?

        fileprivate init(method: String, url: String, header: [String: String], body: String? = nil) {
            self.method = method
            self.url = url
            self.header = header
            self.body = body
        }
    }

    static func codexUsage(accountID: String?) -> Call {
        var header = ["Authorization": "Bearer $TOKEN$", "User-Agent": "codex-cli"]
        if let accountID { header["Chatgpt-Account-Id"] = accountID }
        return Call(method: "GET", url: "https://chatgpt.com/backend-api/wham/usage", header: header)
    }

    /// The daily endpoint first, then production.
    static func antigravityQuotaSummary(project: String) -> [Call] {
        let body = String(data: try! JSONSerialization.data(withJSONObject: ["project": project]), encoding: .utf8)
        return ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"].map { host in
            Call(method: "POST", url: "\(host)/v1internal:retrieveUserQuotaSummary", header: [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)",
            ], body: body)
        }
    }

    static let claudeUsage = Call(method: "GET", url: "https://api.anthropic.com/api/oauth/usage", header: [
        "Authorization": "Bearer $TOKEN$",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-cli/2.1.280 (external, cli)",
    ])
}
