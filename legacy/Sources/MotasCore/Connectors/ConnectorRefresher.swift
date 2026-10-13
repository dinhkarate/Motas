import Foundation

public struct ConnectorRefresher: Sendable {
    private let connectors: [any StatusConnector]
    private let readinessEngine: ReadinessEngine
    private let now: @Sendable () -> Date

    public init(
        connectors: [any StatusConnector],
        readinessEngine: ReadinessEngine = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.connectors = connectors
        self.readinessEngine = readinessEngine
        self.now = now
    }

    public func refresh(trigger: RefreshTrigger = .scheduled) async -> StatusSnapshot {
        let capturedAt = now()
        let results = await withTaskGroup(of: ConnectorResult.self) { group in
            for connector in connectors {
                group.addTask {
                    await connector.refresh(trigger: trigger)
                }
            }

            var collected: [ConnectorResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let providers = results.compactMap { result -> ProviderStatus? in
            guard case .provider(let status) = result else { return nil }
            return status
        }.sorted { $0.id < $1.id }

        let proxies = results.compactMap { result -> ProxyStatus? in
            guard case .proxy(let status) = result else { return nil }
            return status
        }.sorted { $0.id < $1.id }

        let readiness = readinessEngine.evaluate(
            providers: providers,
            proxies: proxies,
            at: capturedAt
        )

        return StatusSnapshot(
            capturedAt: capturedAt,
            readiness: readiness,
            providers: providers,
            proxies: proxies
        )
    }
}
