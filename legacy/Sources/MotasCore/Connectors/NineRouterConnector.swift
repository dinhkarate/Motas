import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct NineRouterConfiguration: Sendable, Equatable {
    public let baseURL: URL
    public let role: SourceRole
    public let isRequiredRoute: Bool
    public let dashboardToken: String?
    public let cliToken: String?
    public let quotaCache: QuotaProbeCache?

    public init(
        baseURL: URL,
        role: SourceRole = .primary,
        isRequiredRoute: Bool = true,
        dashboardToken: String? = nil,
        cliToken: String? = nil,
        quotaCache: QuotaProbeCache? = nil
    ) {
        self.baseURL = EndpointNormalizer.baseURL(from: baseURL)
        self.role = role
        self.isRequiredRoute = isRequiredRoute
        self.dashboardToken = dashboardToken
        self.cliToken = cliToken
        self.quotaCache = quotaCache
    }

    public static func == (lhs: NineRouterConfiguration, rhs: NineRouterConfiguration) -> Bool {
        lhs.baseURL == rhs.baseURL
            && lhs.role == rhs.role
            && lhs.isRequiredRoute == rhs.isRequiredRoute
            && lhs.dashboardToken == rhs.dashboardToken
            && lhs.cliToken == rhs.cliToken
            && (lhs.quotaCache == nil) == (rhs.quotaCache == nil)
    }
}

public struct NineRouterConnector: StatusConnector {
    public let id = "9router"
    public let displayName = "9Router"

    private let configuration: NineRouterConfiguration
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        configuration: NineRouterConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    public func refresh(trigger: RefreshTrigger) async -> ConnectorResult {
        let checkedAt = now()
        do {
            let healthResponse = try await transport.send(request(path: "/api/health"))
            guard healthResponse.statusCode == 200 else {
                return .proxy(
                    status(
                        health: healthResponse.statusCode == 401 ? .unauthorized : .degraded,
                        quality: .unavailable,
                        checkedAt: checkedAt,
                        message: "9Router health check returned HTTP \(healthResponse.statusCode)."
                    )
                )
            }

            let health = try JSONDecoder().decode(HealthResponse.self, from: healthResponse.body)
            guard health.ok else {
                return .proxy(
                    status(
                        health: .degraded,
                        quality: .unavailable,
                        checkedAt: checkedAt,
                        message: "9Router responded but did not report healthy status."
                    )
                )
            }

            return .proxy(await loadProtectedDetails(checkedAt: checkedAt, trigger: trigger))
        } catch {
            return .proxy(
                status(
                    health: .unreachable,
                    quality: .unavailable,
                    checkedAt: checkedAt,
                    message: "9Router could not be reached."
                )
            )
        }
    }
}

private extension NineRouterConnector {
    struct HealthResponse: Decodable {
        let ok: Bool
    }

    struct ProviderListResponse: Decodable {
        let connections: [Connection]
    }

    struct Connection: Decodable {
        let id: String
        let provider: String
        let name: String?
        let email: String?
        let isActive: Bool?
        let testStatus: String?
        let authType: String?
    }

    struct NineRouterUsageResponse: Decodable {
        struct Quota: Decodable {
            let used: Double?
            let total: Double?
            let remaining: Double?
            let remainingPercentage: Double?
            let resetAt: String?
            let unlimited: Bool?
        }
        let plan: String?
        let message: String?
        let error: String?
        let quotas: [String: Quota]?
    }

    func loadProtectedDetails(checkedAt: Date, trigger: RefreshTrigger) async -> ProxyStatus {
        guard hasProtectedAccessCredential else {
            return status(
                health: .healthy,
                quality: .partial,
                checkedAt: checkedAt,
                lastSuccessfulAt: checkedAt,
                message: "9Router is running. Add dashboard monitoring access to inspect provider accounts."
            )
        }

        do {
            let response = try await transport.send(request(path: "/api/providers", protected: true))
            switch response.statusCode {
            case 200:
                let payload = try JSONDecoder().decode(ProviderListResponse.self, from: response.body)
                var accounts: [ProxyAccountStatus] = []
                var anyFailure = false
                var anyWindows = false
                for connection in payload.connections {
                    let probed = await probeUsage(
                        connection: connection, trigger: trigger, now: checkedAt)
                    accounts.append(account(from: connection, quotaWindows: probed))
                    anyFailure = anyFailure || probed == nil
                    anyWindows = anyWindows || !(probed?.isEmpty ?? true)
                }
                accounts.sort { $0.id < $1.id }
                let healthyCount = accounts.filter { $0.health == .healthy }.count
                let routeWindows = QuotaAggregation.routeWindows(
                    from: accounts, idPrefix: "9router")
                let health = QuotaAggregation.poolHealth(accounts)
                let quality: DataQuality = anyWindows && !anyFailure ? .fresh : .partial
                return status(
                    health: health,
                    quality: quality,
                    checkedAt: checkedAt,
                    lastSuccessfulAt: checkedAt,
                    message: accounts.isEmpty
                        ? "9Router is running, but no provider accounts were returned."
                        : "\(healthyCount) of \(accounts.count) provider accounts appear active. Quota detail is connector-dependent.",
                    accounts: accounts,
                    quotaWindows: routeWindows
                )
            case 401, 403:
                return status(
                    health: .healthy,
                    quality: .partial,
                    checkedAt: checkedAt,
                    lastSuccessfulAt: checkedAt,
                    message: "9Router is running, but monitoring authorization was rejected."
                )
            default:
                return status(
                    health: .healthy,
                    quality: .partial,
                    checkedAt: checkedAt,
                    lastSuccessfulAt: checkedAt,
                    message: "9Router is running, but provider details returned HTTP \(response.statusCode)."
                )
            }
        } catch {
            return status(
                health: .healthy,
                quality: .partial,
                checkedAt: checkedAt,
                lastSuccessfulAt: checkedAt,
                message: "9Router is running, but provider details could not be decoded."
            )
        }
    }

    var hasProtectedAccessCredential: Bool {
        configuration.dashboardToken?.isEmpty == false || configuration.cliToken?.isEmpty == false
    }

    /// Probes GET /api/usage/{connectionId}. Never appends `?force=1` — that
    /// bypasses 9Router's own 5-minute upstream cache and triggers provider
    /// 429s. A quotas-decode failure degrades to no windows, never an error.
    func probeUsage(
        connection: Connection,
        trigger: RefreshTrigger,
        now: Date
    ) async -> [QuotaWindow]? {
        let authType = connection.authType?.lowercased()
        guard connection.isActive != false,
            authType == "oauth" || authType == "apikey" || authType == "api_key",
            let cache = configuration.quotaCache
        else {
            return nil
        }
        let key = "9router/\(connection.id)"
        if Task.isCancelled { return nil }
        if await !cache.shouldProbe(key: key, trigger: trigger, now: now) {
            return await cache.cached(key: key, now: now)
        }
        do {
            let response = try await transport.send(
                usageRequest(connectionId: connection.id))
            switch response.statusCode {
            case 200:
                let envelope: NineRouterUsageResponse
                do {
                    envelope = try JSONDecoder().decode(
                        NineRouterUsageResponse.self, from: response.body)
                } catch {
                    await cache.markFailure(key: key, now: now)
                    return nil
                }
                guard let quotas = envelope.quotas, !quotas.isEmpty else {
                    await cache.markFailure(key: key, now: now)
                    return nil
                }
                var windows: [QuotaWindow] = []
                for mapKey in quotas.keys.sorted() {
                    let quota = quotas[mapKey]!
                    if quota.unlimited == true { continue }
                    let fraction: Double?
                    if let pct = quota.remainingPercentage {
                        fraction = pct / 100
                    } else if let remaining = quota.remaining,
                        let total = quota.total, total > 0
                    {
                        fraction = remaining / total
                    } else {
                        continue
                    }
                    guard let fraction else { continue }
                    windows.append(
                        QuotaWindow(
                            id: "9router/\(connection.id)/\(QuotaAggregation.slug(mapKey))",
                            name: mapKey,
                            unit: .percentage,
                            remainingFraction: fraction,
                            resetsAt: FlexibleDate.parse(quota.resetAt),
                            isEnforced: true
                        ))
                }
                await cache.store(windows, key: key, now: now)
                return windows
            case 404:
                await cache.markUnsupported(key: key)
                return nil
            default:
                await cache.markFailure(key: key, now: now)
                return nil
            }
        } catch {
            await cache.markFailure(key: key, now: now)
            return nil
        }
    }

    func usageRequest(connectionId: String) -> URLRequest {
        let url = EndpointNormalizer.url(base: configuration.baseURL, path: "/api/usage/\(connectionId)")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = configuration.cliToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-9r-cli-token")
        } else if let token = configuration.dashboardToken, !token.isEmpty {
            request.setValue("auth_token=\(token)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    func request(path: String, protected: Bool = false) -> URLRequest {
        let url = EndpointNormalizer.url(base: configuration.baseURL, path: path)!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if protected {
            if let token = configuration.cliToken, !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "x-9r-cli-token")
            } else if let token = configuration.dashboardToken, !token.isEmpty {
                request.setValue("auth_token=\(token)", forHTTPHeaderField: "Cookie")
            }
        }
        return request
    }

    func account(from connection: Connection, quotaWindows: [QuotaWindow]? = nil) -> ProxyAccountStatus {
        let active = connection.isActive != false
        let testStatus = connection.testStatus?.lowercased()
        let health: OperationalHealth
        if !active {
            health = .unsupported
        } else if ["success", "connected", "healthy", "ok"].contains(testStatus) {
            health = .healthy
        } else if ["failed", "error", "invalid"].contains(testStatus) {
            health = .degraded
        } else {
            health = .unknown
        }

        var finalHealth = health
        if let windows = quotaWindows,
            windows.contains(where: { $0.isEnforced && $0.remainingFraction == 0 })
        {
            finalHealth = .exhausted
        }

        return ProxyAccountStatus(
            id: connection.id,
            label: connection.name?.nonEmpty ?? maskEmail(connection.email) ?? connection.provider,
            provider: connection.provider,
            health: finalHealth,
            quotaWindows: quotaWindows ?? []
        )
    }

    func status(
        health: OperationalHealth,
        quality: DataQuality,
        checkedAt: Date,
        lastSuccessfulAt: Date? = nil,
        message: String,
        accounts: [ProxyAccountStatus] = [],
        quotaWindows: [QuotaWindow] = []
    ) -> ProxyStatus {
        ProxyStatus(
            id: "9router-local",
            name: "9Router",
            role: configuration.role,
            health: health,
            observation: Observation(
                checkedAt: checkedAt,
                lastSuccessfulAt: lastSuccessfulAt,
                quality: quality,
                message: message
            ),
            isRequiredRoute: configuration.isRequiredRoute,
            route: RouteStatus(
                activeTier: .unknown,
                primaryAvailable: health == .healthy ? true : nil,
                fallbackAvailable: nil,
                description: "Fallback availability requires connector-specific quota data."
            ),
            accounts: accounts,
            quotaWindows: quotaWindows,
            endpointLabel: EndpointNormalizer.redactedLabel(for: configuration.baseURL)
        )
    }

    func maskEmail(_ email: String?) -> String? {
        guard let email, let separator = email.firstIndex(of: "@") else { return nil }
        let local = email[..<separator]
        let domain = email[email.index(after: separator)...]
        guard let first = local.first else { return "•••@\(domain)" }
        return "\(first)•••@\(domain)"
    }
}
