import Foundation

/// Reads a 9Router server through its dashboard API.
///
/// All `/api/*` routes need the dashboard `auth_token` cookie from
/// `POST /api/auth/login` (unless the server has login disabled). Usage comes
/// from `GET /api/usage/{connectionId}`, which may refresh the connection's
/// token server-side — acceptable, 9Router owns those tokens.
public actor NineRouterAdapter: ProxyAdapter {
    public let config: ProxyConfig
    let password: String?
    let http: any HTTPClient
    private var authCookie: String?
    var now: @Sendable () -> Date = { Date() }

    public init(config: ProxyConfig, password: String?, http: any HTTPClient) {
        self.config = config
        self.password = password
        self.http = http
    }

    enum Failure: Error { case unauthorized, http(Int), unreadable }

    public func fetch() async -> ProxySnapshot {
        let fetchedAt = now()
        func snapshot(_ health: ProxyHealth, _ accounts: [AccountSnapshot] = []) -> ProxySnapshot {
            ProxySnapshot(id: config.id, name: config.name, kind: .nineRouter, fetchedAt: fetchedAt, health: health, accounts: accounts)
        }
        let connections: [[String: Any]]
        do {
            let data = try await authorizedGET("/api/providers")
            guard let root = JSON.object(data) else { throw Failure.unreadable }
            connections = root.dicts("connections")
        } catch Failure.unauthorized {
            return snapshot(.unauthorized)
        } catch Failure.http(let code) {
            return snapshot(.failed("HTTP \(code)"))
        } catch Failure.unreadable {
            return snapshot(.failed("Unreadable providers response"))
        } catch {
            return snapshot(.unreachable(describe(error)))
        }

        let items = connections.map(Connection.init)
        let accounts = await boundedMap(items, limit: 4) { await self.account(for: $0) }
        return snapshot(.ok, accounts)
    }

    struct Connection: @unchecked Sendable {
        let raw: [String: Any]
        var id: String { raw.string("id") ?? "?" }
        var provider: Provider { Provider(rawValue: raw.string("provider") ?? "unknown") }
        var label: String { raw.string("email") ?? raw.string("name") ?? id }
        var isActive: Bool { raw.bool("isActive") ?? true }
        var plan: String? { raw.dict("providerSpecificData")?.string("chatgptPlanType") }
        var state: (AccountState, String?) {
            if !isActive { return (.disabled, nil) }
            if let code = raw.double("errorCode") { return (.error, "Last request failed (\(Int(code)))") }
            if raw.string("testStatus") == "unavailable" { return (.error, "Marked unavailable by 9Router") }
            return (.active, nil)
        }
    }

    func account(for connection: Connection) async -> AccountSnapshot {
        let (state, message) = connection.state
        var parsed = ProviderUsage.Parsed(quota: .unavailable("Disabled"), plan: connection.plan)
        if state != .disabled {
            do {
                parsed = ProviderUsage.nineRouter(try await authorizedGET("/api/usage/\(connection.id)"))
            } catch Failure.http(let code) {
                parsed = .init(quota: .failed(code == 401 ? "Token refresh failed on 9Router" : "Usage HTTP \(code)"), plan: nil)
            } catch Failure.unauthorized {
                parsed = .init(quota: .failed("Dashboard session rejected"), plan: nil)
            } catch {
                parsed = .init(quota: .failed(describe(error)), plan: nil)
            }
            parsed.plan = parsed.plan ?? connection.plan
        }
        return AccountSnapshot(id: connection.id, provider: connection.provider, label: connection.label,
                               plan: parsed.plan, state: state, stateMessage: message, quota: parsed.quota)
    }

    /// GET with the dashboard cookie; logs in once on 401 and retries.
    /// A 401 after a fresh login on a non-providers route is reported as
    /// `.http(401)` (per-connection token failure), not a session failure.
    func authorizedGET(_ path: String) async throws -> Data {
        if authCookie == nil, password != nil { try await login() }
        var (data, response) = try await get(path)
        if response.statusCode == 401, password != nil, path == "/api/providers" {
            try await login()
            (data, response) = try await get(path)
        }
        switch response.statusCode {
        case 200: return data
        case 401 where path == "/api/providers": throw Failure.unauthorized
        default: throw Failure.http(response.statusCode)
        }
    }

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: config.baseURL.appendingAPIPath(path), timeoutInterval: 45)
        if let authCookie { req.setValue("auth_token=\(authCookie)", forHTTPHeaderField: "Cookie") }
        return try await http.send(req)
    }

    private func login() async throws {
        var req = URLRequest(url: config.baseURL.appendingAPIPath("/api/auth/login"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["password": password ?? ""])
        let (_, response) = try await http.send(req)
        guard response.statusCode == 200 else { throw Failure.unauthorized }
        authCookie = Self.cookie(named: "auth_token", in: response)
        guard authCookie != nil else { throw Failure.unauthorized }
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
