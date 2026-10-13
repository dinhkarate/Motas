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

@Test("Connector refresher combines Claude Code with two proxy routes deterministically")
func connectorRefresherBuildsLivePrototypeSnapshot() async {
    let date = Date(timeIntervalSince1970: 1_750_000_000)
    let provider = MockData.claude(remaining: 0.80, at: date)
    let primaryProxy = MockData.nineRouter(
        role: .informational,
        health: .healthy,
        activeTier: .subscription,
        fallbackAvailable: true,
        at: date
    )
    let fallbackProxy = ProxyStatus(
        id: "cliproxyapi-local",
        name: "CLIProxyAPI",
        role: .fallback,
        health: .healthy,
        observation: Observation(
            checkedAt: date,
            lastSuccessfulAt: date,
            quality: .partial,
            message: "Models are discoverable."
        ),
        isRequiredRoute: false
    )
    let refresher = ConnectorRefresher(
        connectors: [
            StaticConnector(
                id: fallbackProxy.id,
                displayName: fallbackProxy.name,
                result: .proxy(fallbackProxy)
            ),
            StaticConnector(
                id: provider.id,
                displayName: provider.name,
                result: .provider(provider)
            ),
            StaticConnector(
                id: primaryProxy.id,
                displayName: primaryProxy.name,
                result: .proxy(primaryProxy)
            ),
        ],
        now: { date }
    )

    let snapshot = await refresher.refresh()

    #expect(snapshot.providers.map(\.id) == [provider.id])
    #expect(snapshot.proxies.map(\.id) == ["9router-local", "cliproxyapi-local"])
    #expect(snapshot.readiness.state == .ready)
}
