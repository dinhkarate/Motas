import Foundation

/// Reads a CLIProxyAPI server through its management API.
///
/// `POST /v0/management/quota/fetch` is NOT used: it returns 501 for every
/// built-in provider unless a quota plugin is installed. Instead, like the
/// official Management Center, Motas lists `auth-files` and asks the proxy to
/// call each provider's usage URL with that account's token
/// (`POST /v0/management/api-call`, `$TOKEN$` substituted server-side). Those
/// upstream calls are `UpstreamClients` constants.
public struct CLIProxyAPIAdapter: ProxyAdapter {
    public let config: ProxyConfig
    /// nil when empty.
    let managementKey: String?
    let http: any HTTPClient
    let now: @Sendable () -> Date

    public init(config: ProxyConfig, managementKey: String?, http: any HTTPClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.managementKey = managementKey?.isEmpty == false ? managementKey : nil
        self.http = http
        self.now = now
    }

    /// The only requests this adapter can send; `request(_:)` builds them.
    enum Endpoint {
        case authFiles
        case apiCall(UpstreamClients.Call, authIndex: String)
    }

    public func listAccounts() async throws -> [AccountDescriptor] {
        let (data, response) = try await send(.authFiles)
        switch response.statusCode {
        case 200:
            guard let files = JSON.object(data)?["files"] as? [[String: Any]] else {
                throw ProxyAccessError.failed("Unreadable auth-files response")
            }
            let now = now()
            return files.map { Self.descriptor($0, now: now) }
        case 401, 403:
            throw ProxyAccessError.unauthorized("Management key rejected")
        case 404:
            throw ProxyAccessError.failed("Management API not found — enable remote management")
        default:
            throw ProxyAccessError.failed("HTTP \(response.statusCode)")
        }
    }

    public func readUsage(_ account: AccountDescriptor, force: Bool) async throws -> UsageReading {
        guard case .cpa(let authIndex, let codexAccountID, let projectID) = account.locator else {
            return .failed(.transient("Not a CLIProxyAPI account"))
        }
        switch account.provider {
        case .codex:
            let now = now()
            return try await upstream([UpstreamClients.codexUsage(accountID: codexAccountID)], authIndex) {
                ProviderUsage.codex($0, now: now)
            }
        case .antigravity:
            guard let projectID else {
                return .unavailable("Account has no project id", recheckAfter: ProviderUsage.unmeteredRecheck, extras: UsageExtras())
            }
            return try await upstream(UpstreamClients.antigravityQuotaSummary(project: projectID), authIndex,
                                      parse: ProviderUsage.antigravity)
        case .claude:
            return try await upstream([UpstreamClients.claudeUsage], authIndex, parse: ProviderUsage.claude)
        default:
            return .unavailable("Motas cannot read \(account.provider.displayName) quota through CLIProxyAPI yet",
                                recheckAfter: ProviderUsage.unmeteredRecheck, extras: UsageExtras())
        }
    }

    /// Tries each call in turn through `/api-call`; the first upstream 2xx is
    /// parsed. An upstream 403 is transient (Cloudflare, forbidden quota APIs),
    /// only a 401 rejects the account's token.
    func upstream(_ calls: [UpstreamClients.Call], _ authIndex: String, parse: (Data) -> UsageReading) async throws -> UsageReading {
        var reading = UsageReading.failed(.transient("No response"))
        for call in calls {
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await send(.apiCall(call, authIndex: authIndex))
            } catch let error as ProxyAccessError {
                throw error
            } catch let error where isOffline(error) {
                throw ProxyAccessError.offline(describe(error))
            } catch {
                reading = .failed(.transient(describe(error)))
                continue
            }
            switch response.statusCode {
            case 200:
                break
            case 401, 403:
                throw ProxyAccessError.unauthorized("Management key rejected")
            default:
                reading = .failed(.transient("api-call HTTP \(response.statusCode)"))
                continue
            }
            guard let envelope = JSON.object(data) else {
                reading = .failed(.transient("Unreadable api-call response"))
                continue
            }
            let status = envelope.int("status_code") ?? 0
            switch status {
            case 200..<300:
                return parse(Data((envelope["body"] as? String ?? "").utf8))
            case 401:
                reading = .failed(.credentialRejected("Upstream rejected the account token (401)"))
            case 429:
                let until = Dates.retryAfter(Self.header("Retry-After", in: envelope), now: now())
                reading = .failed(.rateLimited(until: until, "Rate limited by upstream (429)"))
            default:
                reading = .failed(.transient("Upstream HTTP \(status)"))
            }
        }
        return reading
    }

    private func send(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await http.send(request(endpoint))
        if (300..<400).contains(response.statusCode) { throw redirected(response) }
        return (data, response)
    }

    /// Builds every request this adapter sends: `GET auth-files`, and
    /// `POST api-call` to an `UpstreamClients` URL.
    private func request(_ endpoint: Endpoint) throws -> URLRequest {
        guard let managementKey else { throw ProxyAccessError.missingCredential }
        var request: URLRequest
        switch endpoint {
        case .authFiles:
            request = URLRequest(url: config.baseURL.appendingAPIPath("/v0/management/auth-files"))
        case .apiCall(let call, let authIndex):
            request = URLRequest(url: config.baseURL.appendingAPIPath("/v0/management/api-call"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var payload: [String: Any] = ["auth_index": authIndex, "method": call.method, "url": call.url, "header": call.header]
            if let body = call.body { payload["data"] = body }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        try checkPlainHTTP(request.url!)
        return request
    }

    /// One `auth-files` entry. `status_message` is "" when there is none and
    /// becomes a note only when the entry is in error or unavailable.
    static func descriptor(_ file: [String: Any], now: Date) -> AccountDescriptor {
        let authIndex = file.string("auth_index") ?? file.string("id") ?? file.string("name") ?? "?"
        let email = file.string("email")
        let idToken = file.dict("id_token")
        let unavailable = file.bool("unavailable") == true
        let retryAt = [file["next_retry_after"]] + file.dicts("cooldowns").flatMap { c in ["until", "next_retry_after", "reset_at"].map { c[$0] } }
        return AccountDescriptor(
            id: authIndex, provider: Provider(rawValue: file.string("provider") ?? file.string("type") ?? "unknown"),
            label: email ?? file.string("label") ?? file.string("name") ?? authIndex, email: email,
            identity: idToken?.string("chatgpt_account_id") ?? email?.lowercased(),
            metadataPlan: ProviderUsage.normalisedPlan(idToken?.string("plan_type")),
            isDisabled: file.bool("disabled") == true,
            cooldownUntil: retryAt.compactMap { Dates.iso($0 as? String) }.filter { $0 > now }.max(),
            coolingDown: unavailable,
            proxyNote: file.string("status") == "error" || unavailable ? file.string("status_message").map { ProxyNote(message: $0) } : nil,
            locator: .cpa(authIndex: authIndex, codexAccountID: idToken?.string("chatgpt_account_id") ?? file.string("account_id"),
                          projectID: file.string("project_id")))
    }

    /// A header of the upstream response inside the `/api-call` envelope.
    static func header(_ name: String, in envelope: [String: Any]) -> String? {
        for (key, value) in envelope.dict("header") ?? [:] where key.caseInsensitiveCompare(name) == .orderedSame {
            return (value as? [String])?.first ?? value as? String
        }
        return nil
    }
}
