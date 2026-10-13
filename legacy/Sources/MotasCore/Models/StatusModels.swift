import Foundation

public enum SourceRole: String, Codable, Sendable, CaseIterable {
    case primary
    case fallback
    case informational
}

public enum OperationalHealth: String, Codable, Sendable, CaseIterable {
    case healthy
    case degraded
    case exhausted
    case unreachable
    case unauthorized
    case unsupported
    case unknown
}

public enum DataQuality: String, Codable, Sendable, CaseIterable {
    case fresh
    case stale
    case partial
    case unavailable
}

public struct Observation: Codable, Sendable, Equatable {
    public let checkedAt: Date
    public let lastSuccessfulAt: Date?
    public let quality: DataQuality
    public let message: String?

    public init(
        checkedAt: Date,
        lastSuccessfulAt: Date? = nil,
        quality: DataQuality,
        message: String? = nil
    ) {
        self.checkedAt = checkedAt
        self.lastSuccessfulAt = lastSuccessfulAt
        self.quality = quality
        self.message = message
    }
}

public enum QuotaUnit: String, Codable, Sendable, CaseIterable {
    case requests
    case tokens
    case credits
    case currency
    case percentage
    case unknown
}

public struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let unit: QuotaUnit
    public let used: Double?
    public let limit: Double?
    public let remainingFraction: Double?
    public let resetsAt: Date?
    public let isEnforced: Bool

    public init(
        id: String,
        name: String,
        unit: QuotaUnit,
        used: Double? = nil,
        limit: Double? = nil,
        remainingFraction: Double? = nil,
        resetsAt: Date? = nil,
        isEnforced: Bool = true
    ) {
        self.id = id
        self.name = name
        self.unit = unit
        self.used = used
        self.limit = limit
        self.remainingFraction = remainingFraction.map { min(max($0, 0), 1) }
        self.resetsAt = resetsAt
        self.isEnforced = isEnforced
    }
}

public struct ProviderStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let role: SourceRole
    public let health: OperationalHealth
    public let observation: Observation
    public let quotaWindows: [QuotaWindow]
    public let detail: String?

    public init(
        id: String,
        name: String,
        role: SourceRole,
        health: OperationalHealth,
        observation: Observation,
        quotaWindows: [QuotaWindow] = [],
        detail: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.health = health
        self.observation = observation
        self.quotaWindows = quotaWindows
        self.detail = detail
    }
}

public enum RouteTier: String, Codable, Sendable, CaseIterable {
    case primary
    case subscription
    case economical
    case free
    case custom
    case unknown
}

public struct RouteStatus: Codable, Sendable, Equatable {
    public let activeTier: RouteTier
    public let primaryAvailable: Bool?
    public let fallbackAvailable: Bool?
    public let description: String?

    public init(
        activeTier: RouteTier,
        primaryAvailable: Bool? = nil,
        fallbackAvailable: Bool? = nil,
        description: String? = nil
    ) {
        self.activeTier = activeTier
        self.primaryAvailable = primaryAvailable
        self.fallbackAvailable = fallbackAvailable
        self.description = description
    }
}

public struct ProxyAccountStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let provider: String?
    public let health: OperationalHealth
    public let quotaWindows: [QuotaWindow]

    public init(
        id: String,
        label: String,
        provider: String? = nil,
        health: OperationalHealth,
        quotaWindows: [QuotaWindow] = []
    ) {
        self.id = id
        self.label = label
        self.provider = provider
        self.health = health
        self.quotaWindows = quotaWindows
    }
}

public struct ProxyStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let role: SourceRole
    public let health: OperationalHealth
    public let observation: Observation
    public let isRequiredRoute: Bool
    public let route: RouteStatus?
    public let accounts: [ProxyAccountStatus]
    public let quotaWindows: [QuotaWindow]
    public let endpointLabel: String?

    public init(
        id: String,
        name: String,
        role: SourceRole,
        health: OperationalHealth,
        observation: Observation,
        isRequiredRoute: Bool = true,
        route: RouteStatus? = nil,
        accounts: [ProxyAccountStatus] = [],
        quotaWindows: [QuotaWindow] = [],
        endpointLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.health = health
        self.observation = observation
        self.isRequiredRoute = isRequiredRoute
        self.route = route
        self.accounts = accounts
        self.quotaWindows = quotaWindows
        self.endpointLabel = endpointLabel
    }
}

public enum ReadinessState: String, Codable, Sendable, CaseIterable {
    case ready
    case caution
    case fallback
    case blocked
    case proxyDown
    case unknown
}

public struct ReadinessAssessment: Codable, Sendable, Equatable {
    public let state: ReadinessState
    public let title: String
    public let explanation: String
    public let primarySourceID: String?
    public let evaluatedAt: Date

    public init(
        state: ReadinessState,
        title: String,
        explanation: String,
        primarySourceID: String? = nil,
        evaluatedAt: Date
    ) {
        self.state = state
        self.title = title
        self.explanation = explanation
        self.primarySourceID = primarySourceID
        self.evaluatedAt = evaluatedAt
    }
}

public struct StatusSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let capturedAt: Date
    public let readiness: ReadinessAssessment
    public let providers: [ProviderStatus]
    public let proxies: [ProxyStatus]

    public init(
        schemaVersion: Int = StatusSnapshot.currentSchemaVersion,
        capturedAt: Date,
        readiness: ReadinessAssessment,
        providers: [ProviderStatus],
        proxies: [ProxyStatus]
    ) {
        self.schemaVersion = schemaVersion
        self.capturedAt = capturedAt
        self.readiness = readiness
        self.providers = providers
        self.proxies = proxies
    }
}
