import Foundation
import Testing
@testable import MotasCore

@Suite("Pools")
struct PoolTests {
    /// A limit window, by default Codex's primary one.
    func limit(_ fraction: Double, _ period: String = "primary", group: String? = nil, reset: Date? = nil,
               duration: TimeInterval? = nil) -> QuotaWindow {
        QuotaWindow(id: "\(group ?? "")-\(period)", label: period, duration: duration, remainingFraction: fraction, resetsAt: reset,
                    group: group, period: period, role: .limit)
    }

    /// An active account with `quota`; windows were read at `observed`.
    func account(_ id: String, _ quota: QuotaReading, provider: Provider = .codex, observed: Date = t0, plan: String? = "free",
                 identity: String? = nil, credits: Int? = nil, cooldownUntil: Date? = nil, coolingDown: Bool = false) -> AccountSnapshot {
        var observedAt: Date?
        if case .windows = quota { observedAt = observed }
        return AccountSnapshot(id: id, provider: provider, label: "\(id)@example.com", identity: identity, plan: plan, state: .active,
                               quota: quota, quotaObservedAt: observedAt, cooldownUntil: cooldownUntil, coolingDown: coolingDown,
                               extras: UsageExtras(resetCredits: credits))
    }

    func proxy(_ accounts: [AccountSnapshot], health: ProxyHealth = .ok) -> ProxySnapshot {
        ProxySnapshot(id: UUID(), name: "p", kind: .nineRouter, fetchedAt: t0, health: health, accounts: accounts)
    }

    /// A proxy whose accounts were each read once, at t0, through `ProxyState`.
    func read(_ reads: [(id: String, provider: Provider, reading: UsageReading)], config: ProxyConfig = productionConfig) -> ProxySnapshot {
        var state = ProxyState(seed: nil)
        let list = reads.map { AccountDescriptor(id: $0.id, provider: $0.provider, label: $0.id) }
        return state.apply(outcome(list, Dictionary(uniqueKeysWithValues: reads.map { ($0.id, $0.reading) })), config: config, now: t0)
    }

    func pools(_ proxies: ProxySnapshot..., staleLimit: TimeInterval = 1800) -> [PoolSummary] {
        Pool.summarize(Snapshot(fetchedAt: t0, proxies: proxies), now: t0, staleLimit: staleLimit)
    }

    /// 9Router's Antigravity usage with these `quotas` entries.
    func antigravity(_ quotas: String) -> UsageReading {
        ProviderUsage.nineRouter(Data(#"{"plan":"Antigravity","quotas":{\#(quotas)}}"#.utf8), provider: .antigravity)
    }

    /// Every production connection, read twice through the real adapter (§11).
    @Test func productionCapture() async throws {
        let monitor = Monitor(http: nineProduction(), secrets: TestSecrets([productionConfig.id: productionToken]), seed: nil,
                              now: { productionNow })
        _ = await monitor.refresh([productionConfig], force: false, reason: "test")
        let snapshot = await monitor.refresh([productionConfig], force: false, reason: "test")
        let pools = Pool.summarize(snapshot, now: productionNow, staleLimit: 1800)
        #expect(pools.map(\.id) == ["codex|free|", "antigravity||gemini", "antigravity||claude-gpt"])
        #expect(pools.map(\.title) == ["Codex", "Gemini", "Claude & GPT"])

        // Free and Go are one tier: 9 active accounts (the 2 disabled ones never count).
        let codex = pools[0]
        #expect(codex.displayName == "Codex · Free")
        #expect(codex.members == 9 && codex.measured == 9 && codex.usable == 5 && codex.exhausted == 4)
        #expect(codex.unknown == 0 && codex.rejected == 0 && codex.stale == 0 && codex.coolingDown == 0)
        #expect(abs(try #require(codex.reserve) - 0.513) < 0.001)
        #expect(codex.resetCredits == 3)
        #expect(codex.nextRecoveryAt == Dates.iso("2026-11-17T03:03:10Z"))
        #expect(codex.nextResetAt == Dates.iso("2026-11-17T03:03:10Z"))
        #expect(codex.lanes.map(\.label) == ["Primary"] && codex.lanes.first?.count == 9)

        // Antigravity pools equal the family buckets; the image model never pools.
        #expect(abs(try #require(pools[1].reserve) - 0.992) < 0.001)
        #expect(pools[1].members == 2 && pools[1].lanes.map(\.label) == ["Weekly"])
        #expect(pools[2].reserve == 1 && pools[2].members == 2)
        #expect(Pool.headline(pools, pinned: nil)?.title == "Codex")

        // Qoder ×9 rejected after two refreshes, but it never had figures: no pool.
        let proxy = try #require(snapshot.proxies.first)
        let rejected = proxy.accounts.filter { if case .rejected = $0.quota { true } else { false } }
        #expect(rejected.count == 9 && rejected.allSatisfy { $0.provider == Provider(rawValue: "qoder") })

        // Not metered: the API-key connections, xAI, and the Qoder account out of credits.
        let unmetered = Pool.unmetered(proxy)
        #expect(unmetered.map(\.name) == ["Chutes", "quotax-oss", "OpenRouter", "Qoder", "xAI"])
        #expect(unmetered.map(\.count) == [1, 1, 2, 1, 1])
        #expect(unmetered.map(\.quotaExceeded) == [false, false, false, true, false])
        #expect(unmetered[2].messages == ["Usage not available for this connection": 2])
        #expect(Pool.disabled(proxy).map(\.provider.displayName) == ["xAI", "Codex", "Codex"])
    }

    @Test func anImageModelAtZeroDoesNotSinkItsFamily() throws {
        let reading = antigravity(#""gemini_weekly":{"total":1000,"remainingPercentage":98},"gemini-3.1-flash-image":{"total":1000,"remainingPercentage":0}"#)
        let result = pools(read([("a", .antigravity, reading)]))
        #expect(result.map(\.title) == ["Gemini"])
        #expect(result.first?.reserve == 0.98)
    }

    /// Without the family buckets, a family is out only when every text model is.
    @Test func aFamilyWithoutBucketsIsItsBestTextModel() throws {
        let reading = antigravity("""
            "gemini-3.8-flash-high":{"total":1000,"remainingPercentage":0},
            "gemini-3.8-flash-low":{"total":1000,"remainingPercentage":40},
            "claude-sonnet-4-6":{"total":1000,"remainingPercentage":0,"resetAt":"2026-11-02T18:10:30Z"},
            "claude-opus-4-6-thinking":{"total":1000,"remainingPercentage":0,"resetAt":"2026-11-02T17:10:30Z"}
            """)
        let result = pools(read([("a", .antigravity, reading)]))
        #expect(result.map(\.title) == ["Gemini", "Claude & GPT"])
        #expect(result[0].reserve == 0.4 && result[0].usable == 1)
        #expect(result[0].lanes == [PoolSummary.Lane(id: "models", label: "Models", mean: 0.4, count: 1)])
        #expect(result[1].reserve == 0 && result[1].exhausted == 1)
        #expect(result[1].nextRecoveryAt == t0 + 3600)    // the first model back
    }

    @Test func rejectedAccountsAreMembersWithoutAValue() throws {
        let codex = try #require(pools(proxy([
            account("a", .windows([limit(0.25)])),
            account("b", .windows([limit(0.75)])),
            account("c", .rejected("Credential refresh failed")),
        ])).first)
        #expect(codex.members == 3 && codex.measured == 2 && codex.rejected == 1)
        #expect(codex.reserve == 0.5)
        #expect(codex.usable == 2)
    }

    @Test func windowsThatResetSinceTheReadAreUnknown() throws {
        let codex = try #require(pools(proxy([
            account("reset", .windows([limit(0, reset: t0 - 60)]), observed: t0 - 600),
            account("onTheDot", .windows([limit(0, reset: t0)]), observed: t0 - 600),
            account("pending", .windows([limit(0, reset: t0 + 60)]), observed: t0 - 600),
            account("later", .windows([limit(0, reset: t0 - 60), limit(0.5, "secondary")]), observed: t0 - 600),
        ])).first)
        #expect(codex.unknown == 2 && codex.measured == 2)
        #expect(codex.exhausted == 1 && codex.usable == 1)    // "later" keeps its secondary window
        #expect(codex.reserve == 0.25)
    }

    @Test func figuresOlderThanTheStaleLimitAreUnknown() throws {
        let codex = try #require(pools(proxy([
            account("old", .windows([limit(0.125)]), observed: t0 - 1801),
            account("limit", .windows([limit(0.5)]), observed: t0 - 1800),
            account("now", .windows([limit(1)])),
        ]), staleLimit: 1800).first)
        #expect(codex.unknown == 1 && codex.measured == 2)
        #expect(codex.reserve == 0.75)
        #expect(codex.stale == 1)    // read before the proxy's latest refresh
    }

    @Test func theSameAccountOnTwoProxiesCountsOnce() throws {
        let codex = try #require(pools(
            proxy([account("a", .windows([limit(0.25)]), observed: t0 - 600, identity: "acct-1"),
                   account("b", .windows([limit(0.5)]))]),
            proxy([account("a", .windows([limit(0.75)]), identity: "acct-1"),
                   account("c", .windows([limit(1)]))])).first)
        #expect(codex.members == 3)
        #expect(codex.reserve == 0.75)    // (0.75 + 0.5 + 1) / 3: the newer read of acct-1 wins
    }

    @Test func exhaustedCoolingAndRecovery() throws {
        let codex = try #require(pools(proxy([
            account("out", .windows([limit(0, reset: t0 + 7200), limit(0.5, "secondary", reset: t0 + 3600)]), credits: 2),
            account("cool", .windows([limit(0.5)]), credits: 5, cooldownUntil: t0 + 1800),
            account("busy", .windows([limit(0.75)]), coolingDown: true),    // CPA `unavailable` without an instant
            account("ok", .windows([limit(1)]), cooldownUntil: t0 - 60),    // a past cooldown is over
        ])).first)
        #expect(codex.usable == 1 && codex.exhausted == 1 && codex.coolingDown == 2)
        #expect(codex.resetCredits == 2)                 // exhausted members only
        #expect(codex.nextRecoveryAt == t0 + 1800)       // the cooldown ends before the window resets
        #expect(codex.nextResetAt == t0 + 3600)
        #expect(codex.lanes.map(\.id) == ["primary", "secondary"])
        #expect(codex.lanes.map(\.count) == [4, 1])
    }

    /// CPA reports a free account's window length, 9Router does not; lanes come from periods.
    @Test func lanesMergeAcrossCPAAnd9Router() throws {
        let cpaBody = try #require(JSON.object(Fixture.data("cpa_apicall_codex_usage"))?["body"] as? String)
        let cpa = read([("cpa", .codex, ProviderUsage.codex(Data(cpaBody.utf8), now: t0))], config: cpaConfig)
        let nine = read([("9r", .codex, ProviderUsage.nineRouter(Fixture.data("9r_prod_usage_codex_partial"), provider: .codex))])
        let result = pools(cpa, nine)
        #expect(result.map(\.title) == ["Codex"])
        let lanes = try #require(result.first?.lanes)
        #expect(lanes.map(\.label) == ["30-day"] && lanes.map(\.count) == [2])
        #expect(abs(lanes[0].mean - 0.31) < 1e-9)
    }

    @Test func accountsOfAnUnhealthyProxyStillCount() throws {
        let codex = try #require(pools(proxy([account("a", .windows([limit(0.25)]), observed: t0 - 600)],
                                             health: .failed(.unreachable("Timed out")))).first)
        #expect(codex.measured == 1 && codex.reserve == 0.25 && codex.stale == 1)
    }

    @Test func tiersTitlesAndTheFixedOrder() throws {
        let geminiCLI = ["gemini-2.5-flash": "flash", "gemini-2.5-pro": "pro"].map { model, group in
            QuotaWindow(id: model, label: model, remainingFraction: 0.5, group: group)
        }
        let result = pools(proxy([
            account("x", .windows([limit(0.5, "daily")]), provider: Provider(rawValue: "xyz"), plan: nil),
            account("g", .windows(geminiCLI), provider: .geminiCLI, plan: "Free"),
            account("p", .windows([limit(0.5)]), plan: "plus"),
            account("f", .windows([limit(0.5)]), plan: "free"),
            account("go", .windows([limit(0.5)]), plan: "Go"),
            account("n", .windows([limit(0.5)]), plan: nil),
            account("c", .windows([limit(0.5, "5h"), limit(0.5, "weekly"), limit(0.5, "weekly", group: "opus")]), provider: .claude,
                    plan: "max"),
            account("ag", .windows([limit(0.5, "weekly", group: "claude-gpt"), limit(0.5, "weekly", group: "gemini")]),
                    provider: .antigravity, plan: nil),
        ]))
        #expect(result.map(\.id) == ["codex|free|", "codex|plus|", "codex||", "claude||", "antigravity||gemini",
                                     "antigravity||claude-gpt", "gemini-cli||pro", "gemini-cli||flash", "xyz||"])
        #expect(result.map(\.title) == ["Codex Free", "Codex Plus", "Codex", "Claude", "Gemini", "Claude & GPT", "Gemini CLI Pro",
                                        "Gemini CLI Flash", "Xyz"])
        #expect(result.map(\.displayName) == ["Codex · Free", "Codex · Plus", "Codex", "Claude", "Antigravity · Gemini",
                                              "Antigravity · Claude & GPT", "Gemini CLI · Pro", "Gemini CLI · Flash", "Xyz"])
        #expect(result[0].members == 2)    // free + go
        #expect(result[3].lanes.map(\.label) == ["5-hour", "Weekly"])    // Claude's opus window stays in the details
        #expect(result[6].lanes.isEmpty)    // Gemini CLI windows have no period
    }

    @Test func headlinePinFallbacksAndGauge() {
        func pool(_ id: String, measured: Int, members: Int? = nil, reserve: Double?) -> PoolSummary {
            let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return PoolSummary(key: PoolKey(provider: Provider(rawValue: parts[0]), tier: parts[1], group: parts[2]), title: id,
                               displayName: id, reserve: reserve, members: members ?? measured, measured: measured)
        }
        let pools = [pool("codex|free|", measured: 9, reserve: 0.5), pool("codex|plus|", measured: 1, members: 3, reserve: 0.1),
                     pool("antigravity||gemini", measured: 2, reserve: 0.9), pool("antigravity||claude-gpt", measured: 2, reserve: 0.3)]
        // Automatic: the lowest reserve among pools measured at least twice.
        #expect(Pool.headline(pools, pinned: nil)?.id == "antigravity||claude-gpt")
        #expect(Pool.gauge(pools, pinned: nil).map(\.id) == ["antigravity||claude-gpt", "codex|free|"])
        // A pin wins, even on a pool measured once.
        #expect(Pool.headline(pools, pinned: "codex|plus|")?.id == "codex|plus|")
        #expect(Pool.gauge(pools, pinned: "codex|plus|").map(\.id) == ["codex|plus|", "antigravity||claude-gpt"])
        // A pin that is missing: its provider's pool with the most members; no such provider: automatic.
        #expect(Pool.headline(pools, pinned: "codex|team|")?.id == "codex|free|")
        #expect(Pool.headline(pools, pinned: "claude||")?.id == "antigravity||claude-gpt")
        // None measured twice: the most measured, then the lower reserve, then the fixed order.
        let thin = [pool("codex|free|", measured: 1, reserve: 0.8), pool("codex|plus|", measured: 1, reserve: 0.2),
                    pool("claude||", measured: 0, reserve: nil)]
        #expect(Pool.headline(thin, pinned: nil)?.id == "codex|plus|")
        #expect(Pool.headline([pool("codex|free|", measured: 0, reserve: nil), pool("claude||", measured: 0, reserve: nil)],
                              pinned: nil)?.id == "codex|free|")
        #expect(Pool.headline([], pinned: "codex|free|") == nil && Pool.gauge([], pinned: nil).isEmpty)
    }

    @Test func providerNames() {
        let ids = ["codex", "claude", "antigravity", "gemini-cli", "xai", "openrouter", "qoder", "chutes", "openai-compatible-chat-1",
                   "anthropic-compatible-2", "iflow"]
        #expect(ids.map { Provider(rawValue: $0).displayName } == ["Codex", "Claude", "Antigravity", "Gemini CLI", "xAI", "OpenRouter",
                                                                    "Qoder", "Chutes", "OpenAI-compatible", "Anthropic-compatible",
                                                                    "Iflow"])
        #expect(Provider(rawValue: "openai-compatible-chat-1").displayName(hint: "quotax-oss") == "quotax-oss")
        #expect(Provider(rawValue: "anthropic-compatible-2").displayName(hint: "relay") == "relay")
        #expect(Provider.codex.displayName(hint: "node") == "Codex")
    }
}
