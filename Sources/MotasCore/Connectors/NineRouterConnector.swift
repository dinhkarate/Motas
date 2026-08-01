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

    public init(
        baseURL: URL,
        role: SourceRole = .primary,
        isRequiredRoute: Bool = true,
        dashboardToken: String? = nil,
        cliToken: String? = nil
    ) {
        self.baseURL = EndpointNormalizer.baseURL(from: baseURL)
        self.role = role
        self.isRequiredRoute = isRequiredRoute
        self.dashboardToken = dashboardToken
        self.cliToken = cliToken
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

    public func refresh() async -> ConnectorResult {
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

            return .proxy(await loadProtectedDetails(checkedAt: checkedAt))
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
    }

    func loadProtectedDetails(checkedAt: Date) async -> ProxyStatus {
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
                let accounts = payload.connections.map(account(from:)).sorted { $0.id < $1.id }
                let healthyCount = accounts.filter { $0.health == .healthy }.count
                let health: OperationalHealth
                if accounts.isEmpty {
                    health = .degraded
                } else if healthyCount == 0 {
                    health = .degraded
                } else {
                    health = .healthy
                }
                return status(
                    health: health,
                    quality: .partial,
                    checkedAt: checkedAt,
                    lastSuccessfulAt: checkedAt,
                    message: accounts.isEmpty
                        ? "9Router is running, but no provider accounts were returned."
                        : "\(healthyCount) of \(accounts.count) provider accounts appear active. Quota detail is connector-dependent.",
                    accounts: accounts
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

    func account(from connection: Connection) -> ProxyAccountStatus {
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

        return ProxyAccountStatus(
            id: connection.id,
            label: connection.name?.nonEmpty ?? maskEmail(connection.email) ?? connection.provider,
            provider: connection.provider,
            health: health
        )
    }

    func status(
        health: OperationalHealth,
        quality: DataQuality,
        checkedAt: Date,
        lastSuccessfulAt: Date? = nil,
        message: String,
        accounts: [ProxyAccountStatus] = []
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
