import Foundation

/// Reads a CLIProxyAPI server through its management API.
///
/// `POST /v0/management/quota/fetch` is NOT used: it returns 501 for every
/// built-in provider unless a quota plugin is installed. Instead, like the
/// official Management Center, Motas lists `auth-files` and asks the proxy to
/// call each provider's usage URL with that account's token
/// (`POST /v0/management/api-call`, `$TOKEN$` substituted server-side).
public struct CLIProxyAPIAdapter: ProxyAdapter {
    public let config: ProxyConfig
    let managementKey: String?
    let http: any HTTPClient
    var now: @Sendable () -> Date = { Date() }

    public init(config: ProxyConfig, managementKey: String?, http: any HTTPClient) {
        self.config = config
        self.managementKey = managementKey
        self.http = http
    }

    public func fetch() async -> ProxySnapshot {
        let fetchedAt = now()
        func snapshot(_ health: ProxyHealth, _ accounts: [AccountSnapshot] = []) -> ProxySnapshot {
            ProxySnapshot(id: config.id, name: config.name, kind: .cliProxyAPI, fetchedAt: fetchedAt, health: health, accounts: accounts)
        }
        guard let managementKey, !managementKey.isEmpty else { return snapshot(.unauthorized) }

        let files: [[String: Any]]
        do {
            let (data, response) = try await http.send(request("GET", "/v0/management/auth-files", key: managementKey))
            switch response.statusCode {
            case 200: break
            case 401, 403: return snapshot(.unauthorized)
            case 404: return snapshot(.failed("Management API not found — enable remote management"))
            default: return snapshot(.failed("HTTP \(response.statusCode)"))
            }
            guard let root = JSON.object(data) else { return snapshot(.failed("Unreadable auth-files response")) }
            files = root.dicts("files")
        } catch {
            return snapshot(.unreachable(describe(error)))
        }

        let items = files.map(AuthFile.init)
        let accounts = await boundedMap(items, limit: 4) { file in await self.account(for: file, key: managementKey) }
        return snapshot(.ok, accounts)
    }

    struct AuthFile: @unchecked Sendable {
        let raw: [String: Any]
        var authIndex: String { raw.string("auth_index") ?? raw.string("id") ?? raw.string("name") ?? "?" }
        var provider: Provider { Provider(rawValue: raw.string("provider") ?? raw.string("type") ?? "unknown") }
        var label: String { raw.string("email") ?? raw.string("label") ?? raw.string("name") ?? authIndex }
        var isDisabled: Bool { raw.bool("disabled") == true }
        var codexAccountID: String? { raw.dict("id_token")?.string("chatgpt_account_id") ?? raw.string("account_id") }
        var codexPlan: String? { raw.dict("id_token")?.string("plan_type") }
        var projectID: String? { raw.string("project_id") }
        var state: (AccountState, String?) {
            if isDisabled { return (.disabled, nil) }
            if raw.string("status") == "error" || raw.bool("unavailable") == true {
                return (.error, raw.string("status_message"))
            }
            return (.active, nil)
        }
    }

    func account(for file: AuthFile, key: String) async -> AccountSnapshot {
        let (state, message) = file.state
        var parsed = ProviderUsage.Parsed(quota: .unavailable("Disabled"), plan: file.codexPlan)
        if state != .disabled {
            parsed = await usage(for: file, key: key)
            parsed.plan = parsed.plan ?? file.codexPlan
        }
        return AccountSnapshot(id: file.authIndex, provider: file.provider, label: file.label,
                               plan: parsed.plan, state: state, stateMessage: message, quota: parsed.quota)
    }

    func usage(for file: AuthFile, key: String) async -> ProviderUsage.Parsed {
        switch file.provider {
        case .codex:
            var header = ["Authorization": "Bearer $TOKEN$", "User-Agent": "codex-cli"]
            if let id = file.codexAccountID { header["Chatgpt-Account-Id"] = id }
            return await upstream(file, key, method: "GET", urls: ["https://chatgpt.com/backend-api/wham/usage"],
                                  header: header, body: nil, parse: ProviderUsage.codex)
        case .antigravity:
            guard let project = file.projectID else { return .init(quota: .unavailable("Account has no project id"), plan: nil) }
            let body = String(data: try! JSONSerialization.data(withJSONObject: ["project": project]), encoding: .utf8)
            return await upstream(file, key, method: "POST", urls: [
                "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
                "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            ], header: [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)",
            ], body: body, parse: ProviderUsage.antigravity)
        case .claude:
            return await upstream(file, key, method: "GET", urls: ["https://api.anthropic.com/api/oauth/usage"], header: [
                "Authorization": "Bearer $TOKEN$",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-cli/2.1.280 (external, cli)",
            ], body: nil, parse: ProviderUsage.claude)
        default:
            return .init(quota: .unavailable("Motas cannot read \(file.provider.displayName) quota yet"), plan: nil)
        }
    }

    /// Tries each URL in turn through `/api-call`; the first 2xx is parsed.
    func upstream(_ file: AuthFile, _ key: String, method: String, urls: [String], header: [String: String],
                  body: String?, parse: (Data) -> ProviderUsage.Parsed) async -> ProviderUsage.Parsed {
        var lastFailure = "No response"
        for url in urls {
            var payload: [String: Any] = ["auth_index": file.authIndex, "method": method, "url": url, "header": header]
            if let body { payload["data"] = body }
            var req = request("POST", "/v0/management/api-call", key: key)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            do {
                let (data, response) = try await http.send(req)
                guard response.statusCode == 200, let envelope = JSON.object(data) else {
                    lastFailure = "Proxy api-call HTTP \(response.statusCode)"
                    continue
                }
                let status = Int(envelope.double("status_code") ?? 0)
                let inner = Data((envelope["body"] as? String ?? "").utf8)
                switch status {
                case 200..<300: return parse(inner)
                case 401, 403: lastFailure = "Upstream rejected the account token (\(status))"
                case 429: lastFailure = "Rate limited by upstream (429)"
                default: lastFailure = "Upstream HTTP \(status)"
                }
            } catch {
                lastFailure = describe(error)
            }
        }
        return .init(quota: .failed(lastFailure), plan: nil)
    }

    func request(_ method: String, _ path: String, key: String) -> URLRequest {
        var req = URLRequest(url: config.baseURL.appendingAPIPath(path), timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return req
    }
}
