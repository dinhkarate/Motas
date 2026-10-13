import Foundation

public struct StatusHistoryPolicy: Sendable, Equatable {
    public let maximumEntries: Int
    public let maximumAge: TimeInterval

    public init(maximumEntries: Int = 500, maximumAge: TimeInterval = 30 * 24 * 60 * 60) {
        self.maximumEntries = max(maximumEntries, 1)
        self.maximumAge = max(maximumAge, 0)
    }

    public static let `default` = StatusHistoryPolicy()
}

public struct HistoryReadinessSummary: Codable, Sendable, Equatable {
    public let state: ReadinessState
    public let title: String
    public let primarySourceID: String?
    public let evaluatedAt: Date

    public init(from assessment: ReadinessAssessment) {
        state = assessment.state
        title = assessment.title
        primarySourceID = assessment.primarySourceID
        evaluatedAt = assessment.evaluatedAt
    }
}

public struct HistoryQuotaSummary: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let unit: QuotaUnit
    public let remainingFraction: Double?
    public let resetsAt: Date?
    public let isEnforced: Bool

    public init(from window: QuotaWindow) {
        id = window.id
        name = window.name
        unit = window.unit
        remainingFraction = window.remainingFraction
        resetsAt = window.resetsAt
        isEnforced = window.isEnforced
    }
}

public struct HistoryProviderSummary: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let role: SourceRole
    public let health: OperationalHealth
    public let quality: DataQuality
    public let quotaWindows: [HistoryQuotaSummary]

    public init(from provider: ProviderStatus) {
        id = provider.id
        name = provider.name
        role = provider.role
        health = provider.health
        quality = provider.observation.quality
        quotaWindows = provider.quotaWindows.map(HistoryQuotaSummary.init)
    }
}

public struct HistoryProxySummary: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let role: SourceRole
    public let health: OperationalHealth
    public let quality: DataQuality
    public let isRequiredRoute: Bool
    public let activeTier: RouteTier?
    public let primaryAvailable: Bool?
    public let fallbackAvailable: Bool?
    public let accountCount: Int

    public init(from proxy: ProxyStatus) {
        id = proxy.id
        name = proxy.name
        role = proxy.role
        health = proxy.health
        quality = proxy.observation.quality
        isRequiredRoute = proxy.isRequiredRoute
        activeTier = proxy.route?.activeTier
        primaryAvailable = proxy.route?.primaryAvailable
        fallbackAvailable = proxy.route?.fallbackAvailable
        accountCount = proxy.accounts.count
    }
}

/// A secret-free, bounded-history entry derived from a normalized snapshot.
public struct StatusHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let capturedAt: Date
    public let readiness: HistoryReadinessSummary
    public let providers: [HistoryProviderSummary]
    public let proxies: [HistoryProxySummary]

    public init(snapshot: StatusSnapshot) {
        capturedAt = snapshot.capturedAt
        readiness = HistoryReadinessSummary(from: snapshot.readiness)
        providers = snapshot.providers.map(HistoryProviderSummary.init)
        proxies = snapshot.proxies.map(HistoryProxySummary.init)
        id = Self.identifier(for: snapshot)
    }

    private static func identifier(for snapshot: StatusSnapshot) -> String {
        let source = snapshot.readiness.primarySourceID ?? "none"
        return "\(snapshot.capturedAt.timeIntervalSince1970)|\(snapshot.readiness.state.rawValue)|\(source)"
    }
}

public struct StatusHistory: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let entries: [StatusHistoryEntry]

    public init(
        schemaVersion: Int = StatusHistory.currentSchemaVersion,
        entries: [StatusHistoryEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries.sorted { $0.capturedAt < $1.capturedAt }
    }

    public func appending(
        snapshot: StatusSnapshot,
        at now: Date,
        policy: StatusHistoryPolicy = .default
    ) -> StatusHistory {
        let entry = StatusHistoryEntry(snapshot: snapshot)
        var nextEntries = entries
        if let latest = nextEntries.last, latest.materiallyMatches(entry) == false {
            nextEntries.append(entry)
        } else if nextEntries.isEmpty {
            nextEntries.append(entry)
        }

        let oldestAllowed = now.addingTimeInterval(-policy.maximumAge)
        nextEntries = nextEntries.filter { $0.capturedAt >= oldestAllowed }
        if nextEntries.count > policy.maximumEntries {
            nextEntries.removeFirst(nextEntries.count - policy.maximumEntries)
        }
        return StatusHistory(entries: nextEntries)
    }

    public var latest: StatusHistoryEntry? { entries.last }
}

private extension StatusHistoryEntry {
    func materiallyMatches(_ other: StatusHistoryEntry) -> Bool {
        readiness.state == other.readiness.state
            && readiness.title == other.readiness.title
            && readiness.primarySourceID == other.readiness.primarySourceID
            && providers == other.providers
            && proxies == other.proxies
    }
}
