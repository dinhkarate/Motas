import Foundation

public enum MockData {
    public static func unknownSnapshot(at date: Date = Date()) -> StatusSnapshot {
        StatusSnapshot(
            capturedAt: date,
            readiness: ReadinessAssessment(
                state: .unknown,
                title: "Readiness unknown",
                explanation: "Open Motas to refresh your AI stack status.",
                evaluatedAt: date
            ),
            providers: [],
            proxies: []
        )
    }

    public static func readySnapshot(at date: Date = Date()) -> StatusSnapshot {
        let providers = [claude(remaining: 0.72, at: date)]
        let proxies = [
            nineRouter(
                health: .healthy,
                activeTier: .subscription,
                fallbackAvailable: true,
                at: date
            ),
            cliProxyAPI(health: .healthy, at: date),
        ]
        let readiness = ReadinessEngine().evaluate(providers: providers, proxies: proxies, at: date)
        return StatusSnapshot(
            capturedAt: date,
            readiness: readiness,
            providers: providers,
            proxies: proxies
        )
    }

    public static func cautionSnapshot(at date: Date = Date()) -> StatusSnapshot {
        let providers = [claude(remaining: 0.14, at: date)]
        let proxies = [
            nineRouter(
                health: .healthy,
                activeTier: .subscription,
                fallbackAvailable: true,
                at: date
            ),
        ]
        let readiness = ReadinessEngine().evaluate(providers: providers, proxies: proxies, at: date)
        return StatusSnapshot(
            capturedAt: date,
            readiness: readiness,
            providers: providers,
            proxies: proxies
        )
    }

    public static func fallbackSnapshot(at date: Date = Date()) -> StatusSnapshot {
        let providers = [claude(remaining: 0, health: .exhausted, at: date)]
        let proxies = [
            nineRouter(
                health: .healthy,
                activeTier: .economical,
                fallbackAvailable: true,
                at: date
            ),
        ]
        let readiness = ReadinessEngine().evaluate(providers: providers, proxies: proxies, at: date)
        return StatusSnapshot(
            capturedAt: date,
            readiness: readiness,
            providers: providers,
            proxies: proxies
        )
    }

    public static func proxyDownSnapshot(at date: Date = Date()) -> StatusSnapshot {
        let proxies = [
            nineRouter(
                health: .unreachable,
                activeTier: .unknown,
                fallbackAvailable: nil,
                at: date
            ),
        ]
        let readiness = ReadinessEngine().evaluate(providers: [], proxies: proxies, at: date)
        return StatusSnapshot(
            capturedAt: date,
            readiness: readiness,
            providers: [],
            proxies: proxies
        )
    }

    public static func claude(
        remaining: Double,
        health: OperationalHealth = .healthy,
        quality: DataQuality = .fresh,
        role: SourceRole = .primary,
        at date: Date = Date()
    ) -> ProviderStatus {
        ProviderStatus(
            id: "claude-code",
            name: "Claude Code",
            role: role,
            health: health,
            observation: Observation(
                checkedAt: date,
                lastSuccessfulAt: quality == .unavailable ? nil : date,
                quality: quality
            ),
            quotaWindows: [
                QuotaWindow(
                    id: "claude-session",
                    name: "5-hour",
                    unit: .percentage,
                    remainingFraction: remaining,
                    resetsAt: date.addingTimeInterval(3 * 60 * 60)
                ),
                QuotaWindow(
                    id: "claude-weekly",
                    name: "Weekly",
                    unit: .percentage,
                    remainingFraction: min(1, remaining + 0.18),
                    resetsAt: date.addingTimeInterval(2 * 24 * 60 * 60)
                ),
            ]
        )
    }

    public static func nineRouter(
        role: SourceRole = .primary,
        health: OperationalHealth,
        quality: DataQuality = .fresh,
        isRequiredRoute: Bool = false,
        activeTier: RouteTier,
        fallbackAvailable: Bool?,
        at date: Date = Date()
    ) -> ProxyStatus {
        ProxyStatus(
            id: "9router-local",
            name: "9Router",
            role: role,
            health: health,
            observation: Observation(
                checkedAt: date,
                lastSuccessfulAt: health == .unreachable ? nil : date,
                quality: quality
            ),
            isRequiredRoute: isRequiredRoute,
            route: RouteStatus(
                activeTier: activeTier,
                primaryAvailable: health == .healthy,
                fallbackAvailable: fallbackAvailable,
                description: "Local AI router"
            ),
            accounts: [
                ProxyAccountStatus(
                    id: "9router-claude-1",
                    label: "Claude account 1",
                    provider: "Claude",
                    health: health == .healthy ? .healthy : .unknown
                ),
                ProxyAccountStatus(
                    id: "9router-codex-1",
                    label: "Codex account 1",
                    provider: "OpenAI",
                    health: health == .healthy ? .healthy : .unknown
                ),
            ],
            endpointLabel: "localhost:20128"
        )
    }

    public static func cliProxyAPI(
        role: SourceRole = .informational,
        health: OperationalHealth,
        quality: DataQuality = .fresh,
        at date: Date = Date()
    ) -> ProxyStatus {
        ProxyStatus(
            id: "cliproxyapi-local",
            name: "CLIProxyAPI",
            role: role,
            health: health,
            observation: Observation(
                checkedAt: date,
                lastSuccessfulAt: health == .healthy ? date : nil,
                quality: quality
            ),
            isRequiredRoute: false,
            route: RouteStatus(
                activeTier: .custom,
                primaryAvailable: health == .healthy,
                fallbackAvailable: nil,
                description: "OpenAI-compatible local endpoint"
            ),
            accounts: [],
            endpointLabel: "localhost"
        )
    }
}
