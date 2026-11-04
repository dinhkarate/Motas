import Foundation
import Testing
@testable import MotasCore
@testable import MotasUI

@Suite("Desktop widget")
struct DesktopWidgetTests {
    let now = productionNow

    func window(_ value: Double) -> QuotaWindow {
        QuotaWindow(id: "session", label: "Primary", remainingFraction: value, period: "primary", role: .limit)
    }

    func account(_ id: String, _ provider: Provider, quota: QuotaReading, state: AccountState = .active,
                 extras: UsageExtras = UsageExtras()) -> AccountSnapshot {
        AccountSnapshot(id: id, provider: provider, label: "\(id)@example.com", state: state, quota: quota,
                        quotaObservedAt: now, extras: extras)
    }

    func proxy(_ accounts: [AccountSnapshot], health: ProxyHealth = .ok) -> ProxySnapshot {
        ProxySnapshot(id: UUID(), name: "p", kind: .nineRouter, fetchedAt: now, health: health, accounts: accounts)
    }

    @Test func statusCardsCoverLiveCheckAndOff() {
        let openrouter = account("or", Provider(rawValue: "openrouter"), quota: .unavailable("Usage not available"))
        let qoder = account("q", Provider(rawValue: "qoder"), quota: .unavailable("No figures"),
                            extras: UsageExtras(quotaExceeded: true))
        let xai = account("x", Provider(rawValue: "xai"), quota: .unavailable("No figures"), state: .disabled)
        let snapshot = Snapshot(fetchedAt: now, proxies: [
            proxy([openrouter]),
            proxy([qoder], health: .failed(.failed("down"))),
            proxy([xai]),
        ])

        let statuses = DesktopWidgetData.statuses(snapshot, pools: [], order: nil)
        #expect(statuses.map(\.name) == ["OpenRouter", "Qoder", "xAI"])
        #expect(statuses.map(\.state) == [.live, .check, .off])
        #expect(statuses.map(\.detail) == ["1 connection", "Proxy unhealthy", "No active account"])
    }

    @Test func aMeteredProviderHasNoStatusCard() {
        let codex = account("c", .codex, quota: .windows([window(0.5)]))
        let snapshot = Snapshot(fetchedAt: now, proxies: [proxy([codex])])
        let pools = Pool.summarize(snapshot, now: now, staleLimit: 1800)
        #expect(pools.count == 1)
        #expect(DesktopWidgetData.statuses(snapshot, pools: pools, order: nil).isEmpty)
    }

    @Test func allRejectedAccountsAreCheckNotLive() {
        let qoder = account("q", Provider(rawValue: "qoder"), quota: .rejected("Credential refresh failed"))
        let snapshot = Snapshot(fetchedAt: now, proxies: [proxy([qoder])])
        let status = DesktopWidgetData.statuses(snapshot, pools: [], order: nil).first
        #expect(status?.state == .check && status?.detail == "Needs re-login")
    }

    @Test func cardsFollowTheSavedOrderAndStopAtSix() {
        let pools = (0..<7).map { index in
            PoolSummary(key: PoolKey(provider: Provider(rawValue: "p\(index)"), tier: "", group: ""),
                        title: "P\(index)", displayName: "P\(index)")
        }
        #expect(DesktopWidgetData.cards(pools: pools, statuses: [], order: nil).map(\.id)
            == pools.prefix(6).map(\.id))
        let saved = [pools[6].id, "missing", pools[0].id, pools[0].id]
        #expect(DesktopWidgetData.cards(pools: pools, statuses: [], order: saved).map(\.id)
            == [pools[6].id, pools[0].id])
    }

    @Test func aSavedStatusCardStaysVisibleAsOff() {
        let openrouter = account("or", Provider(rawValue: "openrouter"), quota: .unavailable("Usage not available"))
        let snapshot = Snapshot(fetchedAt: now, proxies: [proxy([openrouter])])
        let order = [DesktopWidgetData.statusID(.codex), DesktopWidgetData.statusID(Provider(rawValue: "openrouter")),
                     DesktopWidgetData.statusID(Provider(rawValue: "ghost"))]
        let statuses = DesktopWidgetData.statuses(snapshot, pools: [], order: order)
        let cards = DesktopWidgetData.cards(pools: [], statuses: statuses, order: order)
        #expect(cards.map(\.id) == order)
        #expect(cards.last?.statusState == .off)
    }
}

private extension DesktopCard {
    var statusState: DesktopStatusCard.State? {
        if case .status(let status) = self { return status.state }
        return nil
    }
}
