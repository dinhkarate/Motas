import Foundation
import Security
import Testing
@testable import MotasCore

@Suite("Monitor")
struct MonitorTests {
    /// Routes by host to the two captured testbeds.
    func testbeds() -> StubHTTP {
        let cpa = cpaTestbed(), nine = nineTestbed()
        return StubHTTP { req in try (req.url!.host == "cpa.local" ? cpa : nine).handler(req) }
    }

    @Test func refreshesEnabledProxiesInConfigOrder() async {
        let secrets = TestSecrets([cpaConfig.id: "mgmt", nineConfig.id: "pw"])
        var disabled = ProxyConfig(name: "off", kind: .cliProxyAPI, baseURL: URL(string: "http://off.local")!)
        disabled.isEnabled = false
        let snap = await Monitor(http: testbeds(), secrets: secrets, seed: nil, now: { t0 })
            .refresh([nineConfig, disabled, cpaConfig], force: false, reason: "test")
        #expect(snap.fetchedAt == t0)
        #expect(snap.proxies.map(\.name) == ["Testbed 9Router", "Testbed CPA"])
        #expect(snap.proxies.allSatisfy { $0.health.isOK })
        #expect(snap.proxies.map(\.accounts.count) == [2, 2])
    }

    @Test func needsKeychainAccessCarriesAccountsWithoutCountingAFailure() async throws {
        let listing = Flag()
        let http = nineServer(tokens: [productionToken]) { req in
            if req.path == "/api/providers", listing.value { return (500, Data(), [:]) }
            return productionReply(req)
        }
        let secrets = TestSecrets([productionConfig.id: productionToken])
        let monitor = Monitor(http: http, secrets: secrets, seed: nil, now: { t0 })
        let first = try #require(await monitor.refresh([productionConfig], force: false, reason: "test").proxies.first)
        #expect(first.health == .ok && first.accounts.count == 29)

        listing.value = true
        let down = try #require(await monitor.refresh([productionConfig], force: false, reason: "test").proxies.first)
        #expect(down.health == .failed(.failed("HTTP 500")))
        #expect(down.consecutiveFailures == 1 && down.accounts == first.accounts)

        secrets.error = SecretStoreError.needsApproval
        let requests = http.requests.count
        let locked = try #require(await monitor.refresh([productionConfig], force: false, reason: "test").proxies.first)
        #expect(locked.health == .needsKeychainAccess)
        #expect(locked.accounts == first.accounts)
        #expect(locked.consecutiveFailures == 1 && locked.lastSuccessAt == t0)
        #expect(http.requests.count == requests)

        // Any other Keychain error is no proxy failure either: Allow… retries the read.
        secrets.error = KeychainError(status: errSecNoSuchKeychain)
        let broken = try #require(await monitor.refresh([productionConfig], force: false, reason: "test").proxies.first)
        #expect(broken.health == .needsKeychainAccess)
        #expect(broken.accounts == first.accounts && broken.consecutiveFailures == 1)
        #expect(http.requests.count == requests)
    }

    /// Two offline refreshes leave a streak of 2; a Keychain error after them
    /// must not read as the proxy being down.
    @Test func aKeychainErrorNeverAlertsOrCountsAsUnhealthy() async throws {
        let offline = Flag()
        let up = nineProduction()
        let http = StubHTTP { req in
            if offline.value { throw URLError(.notConnectedToInternet) }
            return try up.handler(req)
        }
        let now = TestNow()
        let secrets = TestSecrets([productionConfig.id: productionToken])
        let monitor = Monitor(http: http, secrets: secrets, seed: nil, now: now.function)
        var engine = AlertEngine()
        func refresh() async -> (Snapshot, [QuotaAlert]) {
            let snapshot = await monitor.refresh([productionConfig], force: false, reason: "test")
            let alerts = engine.evaluate(snapshot, pools: [], threshold: 0.2, refreshInterval: 300, online: true, now: now.date)
            now.advance(300)
            return (snapshot, alerts)
        }
        #expect(await refresh().1.isEmpty)
        offline.value = true
        _ = await refresh()
        let (streak, offlineAlerts) = await refresh()
        #expect(streak.proxies.first?.health == .failed(.offline("Network unavailable")))
        #expect(streak.proxies.first?.consecutiveFailures == 2 && offlineAlerts.isEmpty)

        offline.value = false
        secrets.error = KeychainError(status: errSecNoSuchKeychain)
        let (locked, alerts) = await refresh()
        let proxy = try #require(locked.proxies.first)
        #expect(proxy.health == .needsKeychainAccess && proxy.consecutiveFailures == 2)
        #expect(alerts.isEmpty)
        #expect(!proxy.isUnhealthy && !AlertEngine.isDown(proxy))
        #expect(SharedSnapshot(snapshot: locked, threshold: 0.2, pools: [], headlineID: nil, savedAt: now.date).unhealthyProxies == 0)
    }

    @Test func missingCredentialSendsNothing() async throws {
        let http = cpaTestbed()
        let monitor = Monitor(http: http, secrets: TestSecrets([productionConfig.id: ""]), seed: nil)
        let snap = await monitor.refresh([cpaConfig, productionConfig], force: false, reason: "test")
        #expect(snap.proxies.map(\.health) == [.failed(.missingCredential), .failed(.missingCredential)])
        #expect(snap.proxies.allSatisfy { $0.consecutiveFailures == 0 })
        #expect(http.requests.isEmpty)
    }

    @Test func passwordModeMayRunWithoutAPassword() async throws {
        let http = StubHTTP(productionReply)    // a 9Router without login
        var open = productionConfig
        open.auth = .password
        let snap = await Monitor(http: http, secrets: TestSecrets(), seed: nil, now: { t0 }).refresh([open], force: false, reason: "test")
        #expect(snap.proxies.first?.health == .ok)
        #expect(!http.requests.contains { $0.path == "/api/auth/login" })
    }

    /// Qoder ×9 read "returned 401": the first refresh keeps them, the second rejects them.
    @Test func secretChangeKeepsStateButURLChangeResetsIt() async throws {
        let http = nineProduction(tokens: ["tok-a", "tok-b"])
        let secrets = TestSecrets([productionConfig.id: "tok-a"])
        let monitor = Monitor(http: http, secrets: secrets, seed: nil, now: { t0 })
        func rejected(_ config: ProxyConfig) async -> Int {
            let snap = await monitor.refresh([config], force: false, reason: "test")
            return snap.proxies.first?.accounts.filter { if case .rejected = $0.quota { true } else { false } }.count ?? -1
        }
        #expect(await rejected(productionConfig) == 0)
        try await secrets.setSecret("tok-b", for: productionConfig.id)
        #expect(await rejected(productionConfig) == 9)
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "x-9r-cli-token") != nil })
        #expect(http.requests.last?.value(forHTTPHeaderField: "x-9r-cli-token") == "tok-b")

        var moved = productionConfig
        moved.baseURL = URL(string: "https://router2.example.com")!
        #expect(await rejected(moved) == 0)
    }

    @Test func reusesTheNineRouterSessionUntilTheSecretChanges() async throws {
        let http = testbeds()
        let secrets = TestSecrets([nineConfig.id: "pw"])
        let monitor = Monitor(http: http, secrets: secrets, seed: nil)
        _ = await monitor.refresh([nineConfig], force: false, reason: "test")
        _ = await monitor.refresh([nineConfig], force: false, reason: "test")
        #expect(http.requests.filter { $0.path == "/api/auth/login" }.count == 1)
        try await secrets.setSecret("wrong", for: nineConfig.id)
        let snap = await monitor.refresh([nineConfig], force: false, reason: "test")
        #expect(snap.proxies.first?.health == .failed(.unauthorized("Wrong password")))
        #expect(snap.proxies.first?.accounts.count == 2)    // carried
    }

    @Test func removedProxiesDropOutWithTheirState() async throws {
        let secrets = TestSecrets([productionConfig.id: productionToken])
        let monitor = Monitor(http: nineProduction(), secrets: secrets, seed: nil, now: { t0 })
        _ = await monitor.refresh([productionConfig], force: false, reason: "test")
        #expect(await monitor.refresh([], force: false, reason: "test").proxies.isEmpty)
        secrets.error = SecretStoreError.needsApproval
        let snap = await monitor.refresh([productionConfig], force: false, reason: "test")
        #expect(snap.proxies.first?.health == .needsKeychainAccess)
        #expect(snap.proxies.first?.accounts.isEmpty == true)
    }

    @Test func seedsFromTheLegacySnapshot() async throws {
        let legacy = try #require(SharedSnapshot.load(from: Fixture.url("snapshot_v0.2", dir: "legacy"))).snapshot
        let home = try #require(legacy.proxies.first { $0.name == "Home 9Router" })
        var config = ProxyConfig(id: home.id, name: home.name, kind: .nineRouter, baseURL: URL(string: "https://router.example.com/")!,
                                 auth: .password)
        let secrets = TestSecrets()
        secrets.error = SecretStoreError.needsApproval
        let http = nineProduction(tokens: [], password: "pw")
        let monitor = Monitor(http: http, secrets: secrets, seed: legacy, now: { t0 })

        let carried = try #require(await monitor.refresh([config], force: false, reason: "test").proxies.first)
        #expect(carried.health == .needsKeychainAccess)
        #expect(carried.accounts.map(\.id) == home.accounts.map(\.id))
        #expect(carried.accounts.first { $0.id.hasSuffix("007") }?.state == .active)
        #expect(carried.accounts.first { $0.id.hasSuffix("028") }?.quotaObservedAt == home.fetchedAt)
        #expect(http.requests.isEmpty)

        // The seeded state is adopted by the config's URL and survives a refresh that reads.
        secrets.error = nil
        try await secrets.setSecret("pw", for: home.id)
        let read = try #require(await monitor.refresh([config], force: false, reason: "test").proxies.first)
        #expect(read.health == .ok && read.accounts.count == 29)

        config.kind = .cliProxyAPI
        let other = try #require(await monitor.refresh([config], force: false, reason: "test").proxies.first)
        #expect(other.accounts.isEmpty)    // a kind change resets the state
    }

    @Test func testListsOnly() async throws {
        let http = nineProduction()
        let monitor = Monitor(http: http, secrets: TestSecrets(), seed: nil)
        let accounts = try await monitor.test(productionConfig, secret: productionToken).get()
        #expect(accounts.count == 29)
        #expect(http.requests.map(\.path) == ["/api/providers"])
        #expect(await monitor.test(productionConfig, secret: "nope") == .failure(tokenRejected))
    }
}

@Suite("Backward decoding")
struct LegacyDecodingTests {
    @Test func snapshotFrom0_2() throws {
        let shared = try #require(SharedSnapshot.load(from: Fixture.url("snapshot_v0.2", dir: "legacy")))
        #expect(shared.threshold == 0.3)
        #expect(shared.pools.isEmpty && shared.headlineID == nil && shared.savedAt == shared.snapshot.fetchedAt)
        let proxies = shared.snapshot.proxies
        #expect(proxies.map(\.health) == [.ok, .ok, .failed(.unauthorized("")), .failed(.unreachable("Timed out")),
                                          .needsKeychainAccess, .failed(.failed("HTTP 502"))])
        #expect(proxies.allSatisfy { $0.consecutiveFailures == 0 && $0.lastSuccessAt == nil })

        let home = proxies[0].accounts
        #expect(home.map(\.state) == [.active, .active, .active, .active, .active, .disabled])
        #expect(home[1].quota.windows.first?.remainingFraction == 0)
        #expect(home[3].quota == .unavailable("Qoder connected. Usage fetch returned 401."))
        #expect(home[4].quota == .failed("Token refresh failed on 9Router"))
        #expect(home.allSatisfy { $0.proxyNote == nil && $0.extras == UsageExtras() && $0.lockedModels.isEmpty && !$0.coolingDown })
        let window = try #require(proxies[1].accounts.first?.quota.windows.first)
        #expect(window.duration == 2_592_000)
        #expect(window.role == .limit && window.group == nil && window.period == nil)
    }

    @Test func settingsFrom0_2() throws {
        let settings = try SettingsStore(url: Fixture.url("settings_v0.2", dir: "legacy")).load()
        #expect(settings.proxies.map(\.auth) == [.password, .managementKey])
        #expect(settings.proxies.map(\.kind) == [.nineRouter, .cliProxyAPI])
        #expect(settings.refreshInterval == 600 && settings.lowReserveThreshold == 0.3)
        #expect(ProxyConfig(name: "new", kind: .nineRouter, baseURL: URL(string: "https://r.example.com")!).auth == .cliToken)
        #expect(ProxyConfig(name: "new", kind: .cliProxyAPI, baseURL: URL(string: "https://c.example.com")!).auth == .managementKey)
    }

    /// Provider-keyed samples are dropped: their means are not comparable with tiered pools.
    @Test func historyFrom0_2() throws {
        #expect(HistoryStore(url: Fixture.url("history_v0.2", dir: "legacy")).load().isEmpty)
        let store = HistoryStore(url: tempURL("history.json"))
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixture.url("history_v0.2", dir: "legacy"), to: store.url)
        let pool = PoolSummary(key: PoolKey(provider: .codex, tier: "free", group: ""), title: "Codex", displayName: "Codex · Free",
                               reserve: 0.5)
        #expect(try store.record([pool], at: t0, interval: 300) == [PoolSample(at: t0, pool: "codex|free|", reserve: 0.5)])
    }

    @Test(arguments: [ProxyHealth.ok, .needsKeychainAccess, .failed(.missingCredential), .failed(.unauthorized("Wrong password")),
                      .failed(.loginLocked(until: productionNow)), .failed(.offline("Network unavailable")),
                      .failed(.unreachable("Timed out")), .failed(.failed("HTTP 502"))])
    func healthRoundTrips(_ health: ProxyHealth) throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(health)
        #expect(JSON.object(data)?["kind"] is String)
        #expect(try decoder.decode(ProxyHealth.self, from: data) == health)
    }

    @Test func unknownHealthKind() throws {
        #expect(try JSONDecoder().decode(ProxyHealth.self, from: Data(#"{"kind":"exploded"}"#.utf8)) == .failed(.failed("Unknown")))
        #expect(try JSONDecoder().decode(ProxyHealth.self, from: Data(#"{"melted":{}}"#.utf8)) == .failed(.failed("Unknown")))
    }

    @Test func accountRoundTripsWithEveryNewField() throws {
        let account = AccountSnapshot(
            id: "a", provider: .codex, label: "a@example.com", email: "a@example.com", identity: "acct", plan: "free",
            metadataPlan: "plus", state: .active, quota: .rejected("Credential refresh failed"), quotaObservedAt: t0,
            lastReadError: "Timed out", nextReadAt: t0 + 60, rateLimitedUntil: t0 + 90, cooldownUntil: t0 + 120, coolingDown: true,
            lockedModels: ["gpt-6": t0 + 900], proxyNote: ProxyNote(message: "[429]", at: t0), extras: UsageExtras(resetCredits: 1),
            displayHint: "node")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(AccountSnapshot.self, from: encoder.encode(account)) == account)
    }
}
