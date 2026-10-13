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
    public let quotaCache: QuotaProbeCache?

    public init(
        baseURL: URL,
        role: SourceRole = .primary,
        isRequiredRoute: Bool = true,
        proxyAPIKey: String? = nil,
        managementKey: String? = nil,
        quotaCache: QuotaProbeCache? = nil
    ) {
        self.baseURL = EndpointNormalizer.baseURL(from: baseURL)
        self.role = role
        self.isRequiredRoute = isRequiredRoute
        self.proxyAPIKey = proxyAPIKey
        self.managementKey = managementKey
        self.quotaCache = quotaCache
    }

    public static func == (lhs: CLIProxyAPIConfiguration, rhs: CLIProxyAPIConfiguration) -> Bool {
        lhs.baseURL == rhs.baseURL
            && lhs.role == rhs.role
            && lhs.isRequiredRoute == rhs.isRequiredRoute
            && lhs.proxyAPIKey == rhs.proxyAPIKey
            && lhs.managementKey == rhs.managementKey
            && (lhs.quotaCache == nil) == (rhs.quotaCache == nil)
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

    public func refresh(trigger: RefreshTrigger) async -> ConnectorResult {
        let checkedAt = now()
        do {
            let response = try await transport.send(modelsRequest())
            switch response.statusCode {
            case 200:
                let models = (try? JSONDecoder().decode(ModelsResponse.self, from: response.body).data) ?? []
                return .proxy(await loadManagementDetails(checkedAt: checkedAt, modelCount: models.count, trigger: trigger))
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

    func loadManagementDetails(checkedAt: Date, modelCount: Int, trigger: RefreshTrigger) async -> ProxyStatus {
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
                var accounts: [ProxyAccountStatus] = []
                var anyFailure = false
                var anyWindows = false
                for (index, file) in payload.files.enumerated() {
                    let probed = await probeQuota(
                        file: file, position: index, trigger: trigger, now: checkedAt)
                    accounts.append(
                        account(from: file, position: index, quotaWindows: probed.windows, planLabel: probed.planLabel))
                    anyFailure = anyFailure || probed.failed
                    anyWindows = anyWindows || !probed.windows.isEmpty
                }
                accounts.sort { $0.id < $1.id }
                let usable = accounts.filter { $0.health == .healthy }.count
                let routeWindows = QuotaAggregation.routeWindows(
                    from: accounts, idPrefix: "cliproxyapi")
                let health = QuotaAggregation.poolHealth(accounts)
                let quality: DataQuality = anyWindows && !anyFailure ? .fresh : .partial
                let message: String
                if anyWindows {
                    message = "\(usable) of \(accounts.count) accounts available \u{00B7} quota from \(routeWindows.count) provider windows."
                } else {
                    message = "\(usable) of \(accounts.count) accounts appear available; \(modelCount) models are discoverable. Precise quota windows require provider inspection."
                }
                return status(
                    health: health,
                    quality: quality,
                    checkedAt: checkedAt,
                    lastSuccessfulAt: checkedAt,
                    message: message,
                    accounts: accounts,
                    quotaWindows: routeWindows
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

    struct QuotaProbeOutcome: Sendable {
        var windows: [QuotaWindow] = []
        var failed = false
        var planLabel: String? = nil
    }

    struct CPAQuotaResponse: Decodable {
        struct Subscription: Decodable {
            let plan: String?
            let tierName: String?
        }
        struct Bucket: Decodable {
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
            let description: String?
        }
        struct Group: Decodable {
            let displayName: String?
            let buckets: [Bucket]?
        }
        let subscription: Subscription?
        let groups: [Group]?
    }

    struct QuotaFetchBody: Encodable {
        let authIndex: String

        enum CodingKeys: String, CodingKey {
            case authIndex = "auth_index"
        }
    }

    /// Probes POST /v0/management/quota/fetch for one auth file. Never retries,
    /// never touches mutation endpoints. Returns cached windows when the
    /// cooldown suppresses the probe.
    func probeQuota(
        file: AuthFile,
        position: Int,
        trigger: RefreshTrigger,
        now: Date
    ) async -> QuotaProbeOutcome {
        guard let authIndex = file.authIndex?.nonEmpty,
            let cache = configuration.quotaCache
        else {
            return QuotaProbeOutcome()
        }
        let key = "cliproxyapi/\(authIndex)"
        guard await cache.shouldProbe(key: key, trigger: trigger, now: now) else {
            return QuotaProbeOutcome(windows: await cache.cached(key: key, now: now) ?? [])
        }
        do {
            let response = try await transport.send(quotaFetchRequest(authIndex: authIndex))
            switch response.statusCode {
            case 200:
                let payload = try JSONDecoder().decode(CPAQuotaResponse.self, from: response.body)
                var windows: [QuotaWindow] = []
                for group in payload.groups ?? [] {
                    let groupName = group.displayName ?? ""
                    for bucket in group.buckets ?? [] {
                        guard let fraction = bucket.remainingFraction else { continue }
                        let windowName = bucket.window ?? ""
                        let name: String
                        if !groupName.isEmpty, !windowName.isEmpty {
                            name = "\(groupName) \u{00B7} \(windowName)"
                        } else if !groupName.isEmpty {
                            name = groupName
                        } else if !windowName.isEmpty {
                            name = windowName
                        } else {
                            name = "Quota"
                        }
                        windows.append(
                            QuotaWindow(
                                id: "cliproxyapi/\(authIndex)/\(QuotaAggregation.slug(groupName))/\(QuotaAggregation.slug(windowName))",
                                name: name,
                                unit: .percentage,
                                remainingFraction: fraction,
                                resetsAt: FlexibleDate.parse(bucket.resetTime),
                                isEnforced: true
                            ))
                    }
                }
                await cache.store(windows, key: key, now: now)
                var plan: String? = payload.subscription?.plan?.nonEmpty
                if plan == nil, let tier = payload.subscription?.tierName?.nonEmpty {
                    plan = tier
                }
                return QuotaProbeOutcome(windows: windows, planLabel: plan)
            case 501, 404:
                await cache.markUnsupported(key: key)
                return QuotaProbeOutcome(failed: true)
            default:
                await cache.markFailure(key: key, now: now)
                return QuotaProbeOutcome(failed: true)
            }
        } catch {
            await cache.markFailure(key: key, now: now)
            return QuotaProbeOutcome(failed: true)
        }
    }

    func quotaFetchRequest(authIndex: String) -> URLRequest {
        let url = EndpointNormalizer.url(base: configuration.baseURL, path: "/v0/management/quota/fetch")!
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = configuration.managementKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONEncoder().encode(QuotaFetchBody(authIndex: authIndex))
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

    func account(
        from file: AuthFile,
        position: Int,
        quotaWindows: [QuotaWindow] = [],
        planLabel: String? = nil
    ) -> ProxyAccountStatus {
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

        var finalLabel = label
        if let plan = planLabel?.nonEmpty {
            finalLabel = "\(finalLabel) \u{00B7} \(plan)"
        }
        var finalHealth = health
        if quotaWindows.contains(where: { $0.isEnforced && $0.remainingFraction == 0 }) {
            finalHealth = .exhausted
        }

        return ProxyAccountStatus(
            id: stableID,
            label: finalLabel,
            provider: file.provider?.nonEmpty ?? file.type?.nonEmpty,
            health: finalHealth,
            quotaWindows: quotaWindows
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
            quotaWindows: quotaWindows,
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
