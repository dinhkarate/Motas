import Foundation
import Testing
@testable import MotasCore

@Suite("Pool reserve")
struct PoolTests {
    func account(_ provider: Provider, _ quota: QuotaReading, state: AccountState = .active) -> AccountSnapshot {
        AccountSnapshot(id: UUID().uuidString, provider: provider, label: "x", state: state, quota: quota)
    }

    func proxy(_ accounts: [AccountSnapshot], health: ProxyHealth = .ok) -> ProxySnapshot {
        ProxySnapshot(id: UUID(), name: "p", kind: .cliProxyAPI, fetchedAt: .now, health: health, accounts: accounts)
    }

    func w(_ remaining: Double, reset: Date? = nil) -> QuotaWindow {
        QuotaWindow(id: UUID().uuidString, label: "w", remainingFraction: remaining, resetsAt: reset)
    }

    @Test func averagesTightestWindowAcrossProxies() throws {
        let snap = Snapshot(fetchedAt: .now, proxies: [
            proxy([account(.codex, .windows([w(0.8), w(0.4)]))]),
            proxy([account(.codex, .windows([w(1.0)]))]),
        ])
        let codex = try #require(Pool.summarize(snap).first)
        #expect(abs(codex.reserve! - 0.7) < 1e-9)
        #expect(codex.measuredCount == 2)
    }

    @Test func failedCountsAsZeroUnavailableIsUnknownDisabledIgnored() throws {
        let snap = Snapshot(fetchedAt: .now, proxies: [proxy([
            account(.codex, .windows([w(1.0)])),
            account(.codex, .failed("401")),
            account(.codex, .unavailable("none")),
            account(.codex, .windows([w(0.0)]), state: .disabled),
        ])])
        let codex = try #require(Pool.summarize(snap).first)
        #expect(codex.reserve == 0.5)
        #expect(codex.measuredCount == 2)
        #expect(codex.unknownCount == 1)
        #expect(codex.exhaustedCount == 1)
    }

    @Test func onlyUnknownAccountsGiveNilReserveNotZero() throws {
        let snap = Snapshot(fetchedAt: .now, proxies: [proxy([account(.geminiCLI, .unavailable("429"))])])
        let pool = try #require(Pool.summarize(snap).first)
        #expect(pool.reserve == nil)
        #expect(Pool.headline([pool]) == nil)
    }

    @Test func unhealthyProxiesAreNotCounted() {
        let snap = Snapshot(fetchedAt: .now, proxies: [proxy([account(.codex, .windows([w(0.1)]))], health: .unreachable("x"))])
        #expect(Pool.summarize(snap).isEmpty)
    }

    @Test func headlineIsLowestReserveAndNextResetIsEarliest() throws {
        let soon = Date(timeIntervalSince1970: 100), later = Date(timeIntervalSince1970: 200)
        let snap = Snapshot(fetchedAt: .now, proxies: [proxy([
            account(.codex, .windows([w(0.2, reset: later)])),
            account(.codex, .windows([w(0.1, reset: soon)])),
            account(.antigravity, .windows([w(1.0, reset: soon)])),
        ])])
        let pools = Pool.summarize(snap)
        let headline = try #require(Pool.headline(pools))
        #expect(headline.provider == .codex)
        #expect(headline.nextReset == soon)
        #expect(pools.first { $0.provider == .antigravity }?.nextReset == nil)
    }

    @Test func endToEndAgainstBothTestbeds() async throws {
        let cpa = await CLIProxyAPIAdapter(config: cpaConfig, managementKey: "mgmt", http: cpaTestbed()).fetch()
        let nine = await NineRouterAdapter(config: nineConfig, password: "pw", http: nineTestbed()).fetch()
        let pools = Pool.summarize(Snapshot(fetchedAt: .now, proxies: [cpa, nine]))
        #expect(pools.map(\.provider) == [.antigravity, .codex, .geminiCLI])
        let codex = try #require(pools.first { $0.provider == .codex })
        #expect(codex.reserve == 0)
        #expect(codex.exhaustedCount == 2)
        #expect(pools.first { $0.provider == .antigravity }?.reserve == 1)
        #expect(pools.first { $0.provider == .geminiCLI }?.unknownCount == 1)
        #expect(Pool.headline(pools)?.provider == .codex)
    }
}
