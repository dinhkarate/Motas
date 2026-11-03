import Foundation

/// Reads a 9Router server through its dashboard API: `GET /api/providers`
/// lists the connections and `GET /api/usage/{id}` reads one (9Router may
/// refresh that connection's token server-side, which is its own business).
///
/// `/api/*` takes either the `x-9r-cli-token` header (`.cliToken`) or the
/// `auth_token` cookie from `POST /api/auth/login` (`.password`). The login
/// guards live here and survive refreshes, because Monitor keeps the adapter
/// until kind, URL, auth or secret changes: a wrong password must never feed
/// 9Router's per-IP lockout.
public actor NineRouterAdapter: ProxyAdapter {
    public let config: ProxyConfig
    /// The CLI token or the dashboard password, per `config.auth`; nil when empty.
    let secret: String?
    let http: any HTTPClient
    let now: @Sendable () -> Date
    private var session: (cookie: String, obtainedAt: Date)?
    /// The one login in flight, shared by `listAccounts` and every `readUsage`.
    private var loginTask: Task<String, any Error>?
    /// After a refused login, no new attempt before `until`.
    private var loginGuard: (until: Date, error: ProxyAccessError)?

    public init(config: ProxyConfig, secret: String?, http: any HTTPClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.secret = secret?.isEmpty == false ? secret : nil
        self.http = http
        self.now = now
    }

    /// The only requests this adapter can send; `request(_:cookie:)` builds them.
    enum Endpoint {
        case providers
        case usage(ConnectionID, force: Bool)
        case login
    }

    /// A connection id that is safe in a URL path: `^[A-Za-z0-9_-]{1,128}$`.
    struct ConnectionID {
        let value: String

        init?(_ value: String) {
            guard value.wholeMatch(of: /[A-Za-z0-9_-]{1,128}/) != nil else { return nil }
            self.value = value
        }
    }

    public func listAccounts() async throws -> [AccountDescriptor] {
        let (data, response) = try await send(.providers)
        switch response.statusCode {
        case 200:
            guard let connections = JSON.object(data)?["connections"] as? [[String: Any]] else {
                throw ProxyAccessError.failed("Unreadable /api/providers response")
            }
            let now = now()
            return connections.compactMap { Self.descriptor($0, now: now) }
        case 404:
            throw ProxyAccessError.failed("9Router API not found at this URL")
        default:
            throw ProxyAccessError.failed("HTTP \(response.statusCode)")
        }
    }

    public func readUsage(_ account: AccountDescriptor, force: Bool) async throws -> UsageReading {
        guard let id = ConnectionID(account.id) else { return .failed(.transient("Unexpected connection id")) }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await send(.usage(id, force: force))
        } catch let error as ProxyAccessError {
            throw error
        } catch let error where isOffline(error) {
            throw ProxyAccessError.offline(describe(error))
        } catch {
            return .failed(.transient(describe(error)))
        }
        let text = JSON.object(data)?.string("error")
        switch response.statusCode {
        case 200:
            return ProviderUsage.nineRouter(data, provider: account.provider)
        case 401, 403:
            // Not the session (`send` handled that): e.g. "Credential refresh failed: …".
            return .failed(.credentialRejected(text ?? "HTTP \(response.statusCode)"))
        case 404:
            return .failed(.transient("Connection no longer on the proxy"))
        case 429:
            let until = Dates.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now())
            return .failed(.rateLimited(until: until, text ?? "HTTP 429"))
        default:
            return .failed(.transient(text ?? "HTTP \(response.statusCode)"))
        }
    }

    /// Sends `endpoint` with the credential. A session 401 never reaches the
    /// caller: without a secret it is `.missingCredential`; a rejected CLI token
    /// is `.unauthorized`; in password mode the cookie that failed is dropped
    /// and the request is retried once after a fresh (single-flight) login.
    private func send(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        let cookie = try await sessionCookie()
        var (data, response) = try await http.send(request(endpoint, cookie: cookie))
        if Self.isSessionRejection(response, data) {
            guard secret != nil else { throw ProxyAccessError.missingCredential }
            guard config.auth == .password else {
                throw ProxyAccessError.unauthorized(
                    "CLI token rejected — machine-id or auth/cli-secret changed on the server; derive the token again")
            }
            if session?.cookie == cookie { session = nil }
            let fresh = try await sessionCookie()
            (data, response) = try await http.send(request(endpoint, cookie: fresh))
            if Self.isSessionRejection(response, data) { throw ProxyAccessError.unauthorized("9Router rejected the session") }
        }
        if (300..<400).contains(response.statusCode) { throw redirected(response) }
        return (data, response)
    }

    /// The dashboard cookie in password mode, logging in when there is none or
    /// it is 23 h old. nil in token mode or without a secret.
    private func sessionCookie() async throws -> String? {
        guard config.auth == .password, secret != nil else { return nil }
        if let session, now().timeIntervalSince(session.obtainedAt) < 23 * 3600 { return session.cookie }
        if let loginTask { return try await loginTask.value }
        if let loginGuard, now() < loginGuard.until { throw loginGuard.error }
        let task = Task { try await self.logIn() }
        loginTask = task
        return try await task.value
    }

    private func logIn() async throws -> String {
        defer { loginTask = nil }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request(.login, cookie: nil))
        } catch {
            throw ProxyAccessError(error)
        }
        let now = now()
        let body = JSON.object(data)
        let text = body?.string("error") ?? ""
        switch response.statusCode {
        case 200:
            if let cookie = Self.cookie(named: "auth_token", in: response) {
                session = (cookie, now)
                return cookie
            }
        case 401:
            throw refuseLogins(.unauthorized("Wrong password"), until: now.addingTimeInterval(30 * 60))
        case 429:
            let until = body?.double("retryAfter").map { now.addingTimeInterval($0) }
                ?? Dates.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now)
                ?? now.addingTimeInterval(60)
            throw refuseLogins(.loginLocked(until: until), until: until)
        case 403 where text.hasPrefix("Password login is disabled"):
            throw refuseLogins(.unauthorized("Password login is disabled on this 9Router — use a CLI token"),
                               until: now.addingTimeInterval(30 * 60))
        case 403 where text.hasPrefix("Default password must be changed"):
            throw refuseLogins(.unauthorized("Change the default 9Router password first, or use a CLI token"),
                               until: now.addingTimeInterval(30 * 60))
        case 300..<400:
            throw redirected(response)
        default:
            break
        }
        throw ProxyAccessError.failed("Login HTTP \(response.statusCode)")
    }

    private func refuseLogins(_ error: ProxyAccessError, until: Date) -> ProxyAccessError {
        loginGuard = (until, error)
        return error
    }

    /// Builds every request this adapter sends. The CLI token goes on
    /// providers and usage only; the password only in the login body.
    private func request(_ endpoint: Endpoint, cookie: String?) throws -> URLRequest {
        var request: URLRequest
        switch endpoint {
        case .providers:
            request = URLRequest(url: config.baseURL.appendingAPIPath("/api/providers"))
        case .usage(let id, let force):
            let path = id.value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id.value
            request = URLRequest(url: config.baseURL.appendingAPIPath("/api/usage/\(path)" + (force ? "?force=1" : "")))
        case .login:
            request = URLRequest(url: config.baseURL.appendingAPIPath("/api/auth/login"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["password": secret ?? ""])
        }
        if case .login = endpoint {} else {
            if config.auth != .password, let secret { request.setValue(secret, forHTTPHeaderField: "x-9r-cli-token") }
            if let cookie { request.setValue("auth_token=\(cookie)", forHTTPHeaderField: "Cookie") }
        }
        if secret != nil { try checkPlainHTTP(request.url!) }
        return request
    }

    /// The middleware's own 401, `{"error":"Unauthorized"}`: Motas's session
    /// or token was refused. Never a verdict on an account.
    static func isSessionRejection(_ response: HTTPURLResponse, _ data: Data) -> Bool {
        response.statusCode == 401 && JSON.object(data)?.string("error") == "Unauthorized"
    }

    /// One `/api/providers` connection. `testStatus`, `errorCode` and
    /// `lastError` describe 9Router's last request and are often weeks old,
    /// so they only become a note, never a state.
    static func descriptor(_ connection: [String: Any], now: Date) -> AccountDescriptor? {
        guard let id = connection.string("id") else { return nil }
        let provider = Provider(rawValue: connection.string("provider") ?? "unknown")
        let specific = connection.dict("providerSpecificData") ?? [:]
        let email = connection.string("email")
        var locks: [String: Date] = [:]
        for (key, value) in connection where key.hasPrefix("modelLock_") {
            if let until = Dates.iso(value as? String), until > now { locks[String(key.dropFirst("modelLock_".count))] = until }
        }
        let accountLock = locks.removeValue(forKey: "__all")
        let compatible = provider.rawValue.hasPrefix("openai-compatible-") || provider.rawValue.hasPrefix("anthropic-compatible-")
        return AccountDescriptor(
            id: id, provider: provider,
            label: email ?? connection.string("displayName") ?? connection.string("name") ?? id, email: email,
            identity: specific.string("chatgptAccountId") ?? email?.lowercased(),
            metadataPlan: ProviderUsage.normalisedPlan(specific.string("chatgptPlanType")),
            isDisabled: connection.bool("isActive") == false,
            cooldownUntil: [Dates.iso(connection.string("rateLimitedUntil")), accountLock].compactMap { $0 }.filter { $0 > now }.max(),
            lockedModels: locks,
            proxyNote: connection.string("lastError").map { ProxyNote(message: $0, at: Dates.iso(connection.string("lastErrorAt"))) },
            displayHint: compatible ? specific.string("nodeName") : nil)
    }

    static func cookie(named name: String, in response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        for part in header.split(separator: ",").flatMap({ $0.split(separator: ";") }) {
            let pair = part.trimmingCharacters(in: .whitespaces)
            if pair.hasPrefix(name + "=") { return String(pair.dropFirst(name.count + 1)) }
        }
        return nil
    }
}
