import Foundation
import Testing
@testable import MotasCore

func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("motas-tests-\(UUID().uuidString)").appendingPathComponent(name)
}

/// A Codex Free pool with the counts these tests need; every measured
/// account is usable unless the reserve is at 0.
private func codexPool(_ reserve: Double?, measured: Int = 2, usable: Int? = nil, unknown: Int = 0, back: Date? = nil,
                       credits: Int = 0) -> PoolSummary {
    PoolSummary(key: PoolKey(provider: .codex, tier: "free", group: ""), title: "Codex", displayName: "Codex · Free", reserve: reserve,
                members: measured + unknown, measured: measured,
                usable: usable ?? ((reserve ?? 0) > Pool.exhaustedThreshold ? measured : 0), unknown: unknown,
                nextRecoveryAt: back, resetCredits: credits)
}

@Suite("Settings")
struct SettingsTests {
    @Test func missingFileGivesEmptyDefaults() throws {
        let settings = try SettingsStore(url: tempURL("settings.json")).load()
        #expect(settings.proxies.isEmpty)
        #expect(settings.refreshInterval == 300)
    }

    @Test func roundTripsWithoutSecrets() throws {
        let store = SettingsStore(url: tempURL("settings.json"))
        try store.save(MotasSettings(proxies: [cpaConfig, nineConfig], refreshInterval: 120))
        #expect(try store.load().proxies == [cpaConfig, nineConfig])
        let saved = try #require(JSON.object(Data(contentsOf: store.url))?["proxies"] as? [[String: Any]])
        #expect(saved.allSatisfy { Set($0.keys) == ["auth", "baseURL", "id", "isEnabled", "kind", "name"] })
    }

    @Test func toleratesMissingKeysFromOlderVersions() throws {
        let store = SettingsStore(url: tempURL("settings.json"))
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"proxies":[]}"#.utf8).write(to: store.url)
        #expect(try store.load().lowReserveThreshold == 0.2)
    }

    @Test func corruptFileThrowsAndIsKept() throws {
        let store = SettingsStore(url: tempURL("settings.json"))
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{nope".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == Data("{nope".utf8))
    }

    /// The app only knew proxy A; the CLI added B meanwhile.
    @Test func updateKeepsWhatAnotherWriterSaved() throws {
        let store = SettingsStore(url: tempURL("settings.json"))
        try store.save(MotasSettings(proxies: [cpaConfig]))
        try store.update { $0.proxies.append(nineConfig) }
        let saved = try store.update { $0.refreshInterval = 120 }
        #expect(saved.proxies == [cpaConfig, nineConfig] && saved.refreshInterval == 120)
        #expect(try store.load() == saved)
    }

    @Test func updateRefusesACorruptFile() throws {
        let store = SettingsStore(url: tempURL("settings.json"))
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{nope".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.update { $0.proxies = [cpaConfig] } }
        #expect(try Data(contentsOf: store.url) == Data("{nope".utf8))
    }

    @Test func refreshIntervalIsClamped() {
        #expect(MotasSettings(refreshInterval: 5).clampedRefreshInterval == 60)
        #expect(MotasSettings(refreshInterval: 99_999).clampedRefreshInterval == 3600)
    }

    @Test func staleLimitIsThreeIntervalsAndAtLeastHalfAnHour() {
        #expect(MotasSettings(refreshInterval: 300).staleLimit == 1800)
        #expect(MotasSettings(refreshInterval: 900).staleLimit == 2700)
        #expect(MotasSettings(refreshInterval: 99_999).staleLimit == 10_800)
    }
}

@Suite("UI preferences")
struct UIPreferencesTests {
    @Test func readAndWriteTheInjectedSuite() throws {
        // A suite named by an absolute path is the plist at that path, so
        // nothing is left in ~/Library/Preferences.
        let name = tempURL("preferences").path
        try FileManager.default.createDirectory(atPath: (name as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UIPreferences(defaults: defaults)
        #expect(preferences.menuBarPool == nil && preferences.desktopWidgetCards == nil)
        #expect(!preferences.desktopWidgetEnabled && !preferences.desktopWidgetLocked)
        #expect(!preferences.onboardingDone && !preferences.legacyKeychainMigrated)

        preferences.menuBarPool = "codex|free|"
        preferences.desktopWidgetEnabled = true
        preferences.desktopWidgetLocked = true
        preferences.desktopWidgetCards = ["antigravity||gemini", "codex|free|"]
        preferences.onboardingDone = true
        preferences.legacyKeychainMigrated = true
        #expect(defaults.string(forKey: "menuBarPool") == "codex|free|")
        #expect(defaults.bool(forKey: "desktopWidget.enabled") && defaults.bool(forKey: "desktopWidget.locked"))
        #expect(defaults.stringArray(forKey: "desktopWidget.cards") == ["antigravity||gemini", "codex|free|"])
        #expect(defaults.bool(forKey: "onboardingDone") && defaults.bool(forKey: "legacyKeychainMigrated"))

        preferences.menuBarPool = nil
        #expect(preferences.menuBarPool == nil)
    }
}

@Suite("History")
struct HistoryTests {
    @Test func recordsOncePerPoolPerIntervalAndPrunes() throws {
        let store = HistoryStore(url: tempURL("history.json"), retention: 1000)
        let start = Date(timeIntervalSince1970: 10_000)
        let gemini = PoolSummary(key: PoolKey(provider: .antigravity, tier: "", group: "gemini"), title: "Gemini",
                                 displayName: "Antigravity · Gemini", reserve: 1)
        try store.record([codexPool(0.5), codexPool(nil)], at: start, interval: 100)    // no reserve: no sample
        try store.record([codexPool(0.375), gemini], at: start + 50, interval: 100)      // too soon for Codex only
        try store.record([codexPool(0.25)], at: start + 150, interval: 100)
        #expect(store.load() == [PoolSample(at: start, pool: "codex|free|", reserve: 0.5),
                                 PoolSample(at: start + 50, pool: "antigravity||gemini", reserve: 1),
                                 PoolSample(at: start + 150, pool: "codex|free|", reserve: 0.25)])
        let samples = try store.record([codexPool(0.125)], at: start + 1_020, interval: 100)    // the first sample expires
        #expect(samples.map(\.reserve) == [1, 0.25, 0.125])
        #expect(store.load() == samples)
    }

    @Test func unreadableElementsAreSkipped() throws {
        let store = HistoryStore(url: tempURL("history.json"))
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"at":10000,"pool":"codex|free|","reserve":0.5},{"at":10000,"provider":"codex","reserve":0.5},42]"#.utf8)
            .write(to: store.url)
        #expect(store.load() == [PoolSample(at: Date(timeIntervalSince1970: 10_000), pool: "codex|free|", reserve: 0.5)])
    }
}

@Suite("Alerts")
struct AlertTests {
    let home = UUID()

    /// One proxy, "Home 9Router", with an account per id in `rejected`.
    func snapshot(at offset: TimeInterval, health: ProxyHealth = .ok, failures: Int = 0, rejected: [String] = []) -> Snapshot {
        let accounts = rejected.map {
            AccountSnapshot(id: $0, provider: Provider(rawValue: "qoder"), label: "\($0)@example.com", state: .active,
                            quota: .rejected("Qoder connected. Usage fetch returned 401."))
        }
        return Snapshot(fetchedAt: t0 + offset, proxies: [
            ProxySnapshot(id: home, name: "Home 9Router", kind: .nineRouter, fetchedAt: t0 + offset, health: health, accounts: accounts,
                          consecutiveFailures: failures),
        ])
    }

    func evaluate(_ engine: inout AlertEngine, _ snapshot: Snapshot, _ pools: [PoolSummary] = [], online: Bool = true) -> [QuotaAlert] {
        engine.evaluate(snapshot, pools: pools, threshold: 0.2, refreshInterval: 300, online: online, now: snapshot.fetchedAt)
    }

    @Test func theFirstEvaluationIsABaseline() {
        var engine = AlertEngine()
        let down = ProxyHealth.failed(.unreachable("Timed out"))
        #expect(evaluate(&engine, snapshot(at: 0, health: down, failures: 2, rejected: ["q1"]), [codexPool(0)]).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 300, health: down, failures: 3, rejected: ["q1"]), [codexPool(0)]).isEmpty)
    }

    @Test func aLowPoolIsConfirmedByTime() {
        var engine = AlertEngine()
        #expect(evaluate(&engine, snapshot(at: 0), [codexPool(0.5)]).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 300), [codexPool(0.125)]).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 360), [codexPool(0.125)]).isEmpty)    // a manual refresh cannot confirm it
        let alerts = evaluate(&engine, snapshot(at: 450), [codexPool(0.125)])
        #expect(alerts.map(\.identifier) == ["poolLow:codex|free|"])
        #expect(alerts.first?.title == "Codex is low")
        #expect(alerts.first?.body == "13% · 2/2 usable")
        #expect(alerts.first?.poolID == "codex|free|")
        #expect(evaluate(&engine, snapshot(at: 750), [codexPool(0.125)]).isEmpty)
    }

    @Test func aLowPoolReArmsSilentlyAboveTheMargin() {
        var engine = AlertEngine()
        _ = evaluate(&engine, snapshot(at: 0), [codexPool(0.5)])
        _ = evaluate(&engine, snapshot(at: 300), [codexPool(0.125)])
        #expect(evaluate(&engine, snapshot(at: 600), [codexPool(0.125)]).map(\.kind) == [.poolLow])
        #expect(evaluate(&engine, snapshot(at: 900), [codexPool(0.21875)]).isEmpty)    // above the threshold, within the margin
        #expect(evaluate(&engine, snapshot(at: 1200), [codexPool(0.125)]).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 1500), [codexPool(0.375)]).isEmpty)     // re-armed, with no "recovered" alert
        #expect(evaluate(&engine, snapshot(at: 1800), [codexPool(0.125)]).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 2100), [codexPool(0.125)]).map(\.kind) == [.poolLow])
    }

    @Test func aPoolMeasuredOnceIsNeverLow() {
        var engine = AlertEngine()
        for offset in [0.0, 300, 600, 900] {
            #expect(evaluate(&engine, snapshot(at: offset), [codexPool(0.125, measured: 1)]).isEmpty)
        }
    }

    @Test func anExhaustedPoolAndItsRecovery() throws {
        var engine = AlertEngine()
        let out = codexPool(0, back: try #require(Dates.iso("2026-11-17T12:00:00Z")), credits: 4)
        _ = evaluate(&engine, snapshot(at: 0), [codexPool(0.5)])
        #expect(evaluate(&engine, snapshot(at: 300), [out]).isEmpty)
        let alerts = evaluate(&engine, snapshot(at: 600), [out])
        #expect(alerts.map(\.identifier) == ["poolLow:codex|free|", "poolExhausted:codex|free|"])
        #expect(alerts.map(\.title) == ["Codex is low", "Codex: no usable account"])
        #expect(alerts.map(\.body) == ["0% · 0/2 usable · next back 17 Nov · 4 reset credits", "Until 17 Nov · 4 reset credits"])

        let available = evaluate(&engine, snapshot(at: 900), [codexPool(0.375, usable: 1)])
        #expect(available.map(\.identifier) == ["poolAvailable:codex|free|"])
        #expect(available.first?.title == "Codex: 1 account usable again")
        #expect(evaluate(&engine, snapshot(at: 1200), [codexPool(0.375, usable: 1)]).isEmpty)
    }

    @Test func anUnknownMemberBlocksExhausted() {
        var engine = AlertEngine()
        _ = evaluate(&engine, snapshot(at: 0), [codexPool(0.5)])
        _ = evaluate(&engine, snapshot(at: 300), [codexPool(0, unknown: 1)])
        #expect(evaluate(&engine, snapshot(at: 600), [codexPool(0, unknown: 1)]).map(\.kind) == [.poolLow])
    }

    @Test func aProxyIsDownAfterTwoFailedRefreshesThenBack() {
        var engine = AlertEngine()
        let unreachable = ProxyHealth.failed(.unreachable("Timed out"))
        _ = evaluate(&engine, snapshot(at: 0))
        #expect(evaluate(&engine, snapshot(at: 300, health: unreachable, failures: 1)).isEmpty)
        let down = evaluate(&engine, snapshot(at: 600, health: unreachable, failures: 2))
        #expect(down.map(\.identifier) == ["proxyDown:\(home.uuidString)"])
        #expect(down.first?.title == "Home 9Router unavailable")
        #expect(down.first?.body == "Cannot reach the proxy: Timed out.")
        #expect(down.first?.proxyID == home)
        #expect(evaluate(&engine, snapshot(at: 900, health: unreachable, failures: 3)).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 1200)).map(\.title) == ["Home 9Router is back"])
        #expect(evaluate(&engine, snapshot(at: 1500)).isEmpty)
    }

    @Test func offlineAndAMissingCredentialNeverAlert() {
        var engine = AlertEngine()
        _ = evaluate(&engine, snapshot(at: 0))
        #expect(evaluate(&engine, snapshot(at: 300, health: .failed(.offline("Network unavailable")), failures: 5)).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 600, health: .failed(.missingCredential), failures: 5)).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 900, health: .failed(.unreachable("Timed out")), failures: 5), online: false).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 1200)).isEmpty)    // never down, so never back
    }

    @Test func keychainApprovalNeverAlerts() {
        var engine = AlertEngine()
        _ = evaluate(&engine, snapshot(at: 0))
        #expect(evaluate(&engine, snapshot(at: 300, health: .needsKeychainAccess)).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 600, health: .needsKeychainAccess)).isEmpty)
        #expect(evaluate(&engine, snapshot(at: 900)).isEmpty)
    }

    @Test func newlyRejectedAccountsAreOneAlertPerProxy() {
        var engine = AlertEngine()
        _ = evaluate(&engine, snapshot(at: 0, rejected: ["q0"]))    // already rejected at the baseline
        let five = evaluate(&engine, snapshot(at: 300, rejected: ["q0", "q1", "q2", "q3", "q4", "q5"]))
        #expect(five.map(\.identifier) == ["accountsRejected:\(home.uuidString)"])
        #expect(five.first?.title == "5 accounts on Home 9Router need re-login")
        #expect(five.first?.body == "q1@example.com, q2@example.com, q3@example.com …and 2 more")
        let six = ["q0", "q1", "q2", "q3", "q4", "q5", "q6"]
        let one = evaluate(&engine, snapshot(at: 600, rejected: six))
        #expect(one.map(\.title) == ["1 account on Home 9Router needs re-login"])
        #expect(one.first?.body == "q6@example.com")
        #expect(evaluate(&engine, snapshot(at: 900, rejected: six)).isEmpty)
    }

    /// Qoder ×9 is rejected on the second read; that is one alert, not nine.
    @Test func productionRejectionsAreOneAlert() async {
        let now = TestNow()
        let monitor = Monitor(http: nineProduction(), secrets: TestSecrets([productionConfig.id: productionToken]), seed: nil,
                              now: now.function)
        var engine = AlertEngine()
        var snapshot = await monitor.refresh([productionConfig], force: false, reason: "test")
        #expect(engine.evaluate(snapshot, pools: Pool.summarize(snapshot, now: now.date, staleLimit: 1800), threshold: 0.2,
                                refreshInterval: 300, online: true, now: now.date).isEmpty)
        now.advance(300)
        snapshot = await monitor.refresh([productionConfig], force: false, reason: "test")
        let alerts = engine.evaluate(snapshot, pools: Pool.summarize(snapshot, now: now.date, staleLimit: 1800), threshold: 0.2,
                                     refreshInterval: 300, online: true, now: now.date)
        #expect(alerts.map(\.title) == ["9 accounts on Production 9Router need re-login"])
        #expect(alerts.first?.body == "account1@example.com, account4@example.com, account7@example.com …and 6 more")
    }
}

@Suite("Shared snapshot")
struct SharedSnapshotTests {
    @Test func roundTripsWithPoolsAndProxyCounts() throws {
        func proxy(_ name: String, _ health: ProxyHealth, failures: Int = 0) -> ProxySnapshot {
            ProxySnapshot(id: UUID(), name: name, kind: .nineRouter, fetchedAt: t0, health: health, accounts: [],
                          consecutiveFailures: failures)
        }
        let snapshot = Snapshot(fetchedAt: t0, proxies: [
            proxy("ok", .ok), proxy("keychain", .needsKeychainAccess),
            proxy("blip", .failed(.unreachable("Timed out")), failures: 1),
            proxy("down", .failed(.unreachable("Timed out")), failures: 2),
            proxy("token", .failed(.unauthorized("CLI token rejected")), failures: 1),
            proxy("offline", .failed(.offline("Network unavailable")), failures: 3),
        ])
        var codex = codexPool(0.5, back: t0 + 3600)
        codex.lanes = [PoolSummary.Lane(id: "primary", label: "Primary", mean: 0.5, count: 2)]
        let shared = SharedSnapshot(snapshot: snapshot, threshold: 0.2, pools: [codex], headlineID: codex.id, savedAt: t0 + 5)
        #expect(shared.staleProxies == 5)        // every proxy whose accounts are carried
        #expect(shared.unhealthyProxies == 2)    // down twice, and the rejected token

        let url = tempURL("snapshot.json")
        try shared.save(to: url)
        let loaded = try #require(SharedSnapshot.load(from: url))
        #expect(loaded.snapshot == snapshot && loaded.threshold == 0.2)
        #expect(loaded.pools == [codex] && loaded.headlineID == "codex|free|")
        #expect(loaded.staleProxies == 5 && loaded.unhealthyProxies == 2)
        #expect(loaded.savedAt == t0 + 5)
    }

    @Test func widgetReloadsWaitAQuarterHourUnlessTheHeadlineOrHealthChanges() {
        func digest(_ reserve: Double, usable: Int = 2, headline: String? = "codex|free|", unhealthy: Int = 0) -> WidgetDigest {
            var shared = SharedSnapshot(snapshot: Snapshot(fetchedAt: t0, proxies: []), threshold: 0.2,
                                        pools: [codexPool(reserve, usable: usable)], headlineID: headline, savedAt: t0)
            shared.unhealthyProxies = unhealthy
            return WidgetDigest(shared)
        }
        let last = digest(0.5)
        #expect(last.headlinePercent == 50 && last.pools == ["codex|free|": 50] && last.usable == ["codex|free|": 2])
        #expect(WidgetDigest.shouldReload(last, last: nil, lastReloadAt: nil, now: t0))
        #expect(!WidgetDigest.shouldReload(digest(0.504), last: last, lastReloadAt: t0, now: t0 + 3600))    // same whole percent
        #expect(!WidgetDigest.shouldReload(digest(0.375), last: last, lastReloadAt: t0, now: t0 + 14 * minute))
        #expect(WidgetDigest.shouldReload(digest(0.375), last: last, lastReloadAt: t0, now: t0 + 15 * minute))
        #expect(!WidgetDigest.shouldReload(digest(0.5, usable: 1), last: last, lastReloadAt: t0, now: t0 + 5 * minute))
        #expect(WidgetDigest.shouldReload(digest(0.5, headline: nil), last: last, lastReloadAt: t0, now: t0 + minute))
        #expect(WidgetDigest.shouldReload(digest(0.5, unhealthy: 1), last: last, lastReloadAt: t0, now: t0 + minute))
    }
}
