import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CLIProxyAPIConfiguration: Sendable, Equatable {
    public let baseURL: URL
    public let role: SourceRole
    public let isRequiredRoute: Bool
    public let proxyAPIKey: String?
    public let managementKey: String?

    public init(
        baseURL: URL,
        role: SourceRole = .primary,
        isRequiredRoute: Bool = true,
        proxyAPIKey: String? = nil,
        managementKey: String? = nil
    ) {
        self.baseURL = EndpointNormalizer.baseURL(from: baseURL)
        self.role = role
        self.isRequiredRoute = isRequiredRoute
        self.proxyAPIKey = proxyAPIKey
        self.managementKey = managementKey
    }
}

public struct CLIProxyAPIConnector: StatusConnector {
    public let id = "cliproxyapi"
    public let displayName = "CLIProxyAPI"

    private let configuration: CLIProxyAPIConfiguration
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        configuration: CLIProxyAPIConfiguration,
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
            let response = try await transport.send(modelsRequest())
            switch response.statusCode {
            case 200:
                let models = (try? JSONDecoder().decode(ModelsResponse.self, from: response.body).data) ?? []
                return .proxy(await loadManagementDetails(checkedAt: checkedAt, modelCount: models.count))
            case 401, 403:
                return .proxy(
                    status(
                        health: .unauthorized,
                        quality: .unavailable,
                        checkedAt: checkedAt,
                        message: "CLIProxyAPI is reachable, but the proxy API key was rejected."
                    )
                )
            default:
                return .proxy(
                    status(
                        health: .degraded,
                        quality: .unavailable,
                        checkedAt: checkedAt,
                        message: "CLIProxyAPI model discovery returned HTTP \(response.statusCode)."
                    )
                )
            }
        } catch {
            return .proxy(
                status(
                    health: .unreachable,
                    quality: .unavailable,
                    checkedAt: checkedAt,
                    message: "CLIProxyAPI could not be reached."
                )
            )
        }
    }
}

private extension CLIProxyAPIConnector {
    struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
        }
        let data: [Model]
    }

    struct AuthFilesResponse: Decodable {
        let files: [AuthFile]
    }

    struct AuthFile: Decodable {
        let id: String?
        let authIndex: String?
        let name: String?
        let provider: String?
        let type: String?
        let label: String?
        let email: String?
        let status: String?
        let statusMessage: String?
        let disabled: Bool?
        let unavailable: Bool?
        let success: Int?
        let failed: Int?
        let nextRetryAfter: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case authIndex = "auth_index"
            case name
            case provider
            case type
            case label
            case email
            case status
            case statusMessage = "status_message"
            case disabled
            case unavailable
            case success
            case failed
            case nextRetryAfter = "next_retry_after"
        }
    }

    func loadManagementDetails(checkedAt: Date, modelCount: Int) async -> ProxyStatus {
        guard let managementKey = configuration.managementKey, !managementKey.isEmpty else {
            return status(
                health: .healthy,
                quality: .partial,
                checkedAt: checkedAt,
                lastSuccessfulAt: checkedAt,
                message: "CLIProxyAPI is running with \(modelCount) discoverable models. Add a management key to inspect accounts."
            )
        }

        do {
            let response = try await transport.send(managementRequest(path: "/v0/management/auth-files"))
            switch response.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let payload = try decoder.decode(AuthFilesResponse.self, from: response.body)
                let accounts = payload.files.enumerated()
                    .map { index, file in account(from: file, position: index) }
                    .sorted { $0.id < $1.id }
                let usable = accounts.filter { $0.health == .healthy }.count
                let health: OperationalHealth = accounts.isEmpty || usable == 0 ? .degraded : .healthy
                return status(
                    health: health,
                    quality: .partial,
                    checkedAt: checkedAt,
                    lastSuccessfulAt: checkedAt,
                    message: "\(usable) of \(accounts.count) accounts appear available; \(modelCount) models are discoverable. Precise quota windows require provider inspection.",
                    accounts: accounts
                )
            case 401, 403:
                return status(
                    health: .healthy,
                    quality: .partial,
                    checkedAt: checkedAt,
                    lastSuccessfulAt: checkedAt,
                    message: "CLIProxyAPI is running, but the management key was rejected."
                )
            case 404:
                return status(
                    health: .healthy,
                    quality: .partial,
                    checkedAt: checkedAt,
                    lastSuccessfulAt: checkedAt,
                    message: "CLIProxyAPI is running, but the Management API is disabled or unavailable."
                )
            default:
                return status(
                    health: .healthy,
                    quality: .partial,
                    checkedAt: checkedAt,
                    lastSuccessfulAt: checkedAt,
                    message: "CLIProxyAPI is running, but account inspection returned HTTP \(response.statusCode)."
                )
            }
        } catch {
            return status(
                health: .healthy,
                quality: .partial,
                checkedAt: checkedAt,
                lastSuccessfulAt: checkedAt,
                message: "CLIProxyAPI is running, but account data could not be decoded."
            )
        }
    }

    func modelsRequest() -> URLRequest {
        let url = EndpointNormalizer.url(base: configuration.baseURL, path: "/v1/models")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = configuration.proxyAPIKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func managementRequest(path: String) -> URLRequest {
        let url = EndpointNormalizer.url(base: configuration.baseURL, path: path)!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = configuration.managementKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func account(from file: AuthFile, position: Int) -> ProxyAccountStatus {
        let status = file.status?.lowercased()
        let health: OperationalHealth
        if file.disabled == true {
            health = .unsupported
        } else if file.unavailable == true || status == "error" {
            health = .degraded
        } else if status == "disabled" {
            health = .unsupported
        } else if status == "active" {
            health = .healthy
        } else {
            health = .unknown
        }

        let stableID = file.authIndex?.nonEmpty
            ?? file.id?.nonEmpty
            ?? file.name?.nonEmpty
            ?? anonymousAccountID(for: file, position: position)
        let label = file.label?.nonEmpty
            ?? maskEmail(file.email)
            ?? file.name?.nonEmpty
            ?? file.provider?.nonEmpty
            ?? file.type?.nonEmpty
            ?? "Account"

        return ProxyAccountStatus(
            id: stableID,
            label: label,
            provider: file.provider?.nonEmpty ?? file.type?.nonEmpty,
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
        let fallbackAvailable = accounts.isEmpty ? nil : accounts.contains { $0.health == .healthy }
        return ProxyStatus(
            id: "cliproxyapi-local",
            name: "CLIProxyAPI",
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
                activeTier: .custom,
                primaryAvailable: health == .healthy ? true : nil,
                fallbackAvailable: fallbackAvailable,
                description: "Account routing is managed by CLIProxyAPI."
            ),
            accounts: accounts,
            endpointLabel: EndpointNormalizer.redactedLabel(for: configuration.baseURL)
        )
    }

    func anonymousAccountID(for file: AuthFile, position: Int) -> String {
        let provider = file.provider?.nonEmpty ?? file.type?.nonEmpty ?? "unknown"
        return "anonymous-\(position)-\(provider.lowercased())"
    }

    func maskEmail(_ email: String?) -> String? {
        guard let email, let separator = email.firstIndex(of: "@") else { return nil }
        let local = email[..<separator]
        let domain = email[email.index(after: separator)...]
        guard let first = local.first else { return "•••@\(domain)" }
        return "\(first)•••@\(domain)"
    }
}
