import Foundation
import Testing
@testable import MotasCore

@Test("Static connector returns normalized provider status")
func staticProviderConnector() async {
    let provider = MockData.claude(
        remaining: 0.72,
        at: Date(timeIntervalSince1970: 1_750_000_000)
    )
    let connector = StaticConnector(
        id: provider.id,
        displayName: provider.name,
        result: .provider(provider)
    )

    #expect(await connector.refresh() == .provider(provider))
}

@Test("Static connector returns normalized proxy status")
func staticProxyConnector() async {
    let proxy = MockData.nineRouter(
        health: .healthy,
        activeTier: .subscription,
        fallbackAvailable: true,
        at: Date(timeIntervalSince1970: 1_750_000_000)
    )
    let connector = StaticConnector(
        id: proxy.id,
        displayName: proxy.name,
        result: .proxy(proxy)
    )

    #expect(await connector.refresh() == .proxy(proxy))
}
