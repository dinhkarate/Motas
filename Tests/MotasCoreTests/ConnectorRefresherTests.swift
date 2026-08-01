import Foundation
import Testing
@testable import MotasCore

@Test("Connector refresher gathers results concurrently and evaluates readiness")
func connectorRefresherBuildsSnapshot() async {
    let date = Date(timeIntervalSince1970: 1_750_000_000)
    let provider = MockData.claude(remaining: 0.80, at: date)
    let proxy = MockData.nineRouter(
        role: .informational,
        health: .healthy,
        activeTier: .subscription,
        fallbackAvailable: true,
        at: date
    )
    let refresher = ConnectorRefresher(
        connectors: [
            StaticConnector(id: provider.id, displayName: provider.name, result: .provider(provider)),
            StaticConnector(id: proxy.id, displayName: proxy.name, result: .proxy(proxy)),
        ],
        now: { date }
    )

    let snapshot = await refresher.refresh()

    #expect(snapshot.providers == [provider])
    #expect(snapshot.proxies == [proxy])
    #expect(snapshot.readiness.state == .ready)
    #expect(snapshot.capturedAt == date)
}
