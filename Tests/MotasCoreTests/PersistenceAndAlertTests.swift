import Foundation
import Testing
@testable import MotasCore

func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("motas-tests-\(UUID().uuidString)").appendingPathComponent(name)
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
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!text.lowercased().contains("password"))
        #expect(!text.lowercased().contains("key\""))
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

    @Test func refreshIntervalIsClamped() {
        #expect(MotasSettings(refreshInterval: 5).clampedRefreshInterval == 60)
        #expect(MotasSettings(refreshInterval: 99_999).clampedRefreshInterval == 3600)
    }
}

@Suite("History")
struct HistoryTests {
    func pool(_ p: Provider, _ r: Double?) -> PoolSummary {
        PoolSummary(provider: p, reserve: r, measuredCount: 1, exhaustedCount: 0, unknownCount: 0)
    }

    @Test func recordsSpacesAndPrunes() throws {
        let store = HistoryStore(url: tempURL("history.json"), retention: 1000, spacing: 100)
        let t0 = Date(timeIntervalSince1970: 10_000)
        try store.record([pool(.codex, 0.5), pool(.geminiCLI, nil)], at: t0)
        try store.record([pool(.codex, 0.4)], at: t0.addingTimeInterval(50))   // too soon
        try store.record([pool(.codex, 0.3)], at: t0.addingTimeInterval(150))
        #expect(store.load().map(\.reserve) == [0.5, 0.3])
        try store.record([pool(.codex, 0.2)], at: t0.addingTimeInterval(1_100)) // t0 sample expires
        #expect(store.load().map(\.reserve) == [0.3, 0.2])
    }
}

@Suite("Alerts")
struct AlertTests {
    func snap(_ remaining: Double, health: ProxyHealth = .ok, id: UUID = cpaConfig.id) -> Snapshot {
        let account = AccountSnapshot(id: "a", provider: .codex, label: "a", state: .active,
                                      quota: .windows([QuotaWindow(id: "w", label: "w", remainingFraction: remaining)]))
        return Snapshot(fetchedAt: .now, proxies: [ProxySnapshot(id: id, name: "CPA", kind: .cliProxyAPI, fetchedAt: .now,
                                                                 health: health, accounts: health.isOK ? [account] : [])])
    }

    @Test func firesOnlyOnCrossing() {
        #expect(AlertRules.alerts(previous: snap(0.5), current: snap(0.1), threshold: 0.2).map(\.kind) == [.poolLow(.codex)])
        #expect(AlertRules.alerts(previous: snap(0.1), current: snap(0.05), threshold: 0.2).isEmpty)
        #expect(AlertRules.alerts(previous: snap(0.1), current: snap(0.6), threshold: 0.2).map(\.kind) == [.poolRecovered(.codex)])
    }

    @Test func noAlertsOnFirstRefresh() {
        #expect(AlertRules.alerts(previous: nil, current: snap(0.0), threshold: 0.2).isEmpty)
    }

    @Test func proxyDownAndBack() {
        let down = AlertRules.alerts(previous: snap(0.5), current: snap(0.5, health: .unreachable("Timed out")), threshold: 0.2)
        #expect(down.map(\.kind) == [.proxyDown(cpaConfig.id)])
        #expect(down[0].body.contains("Timed out"))
        let back = AlertRules.alerts(previous: snap(0.5, health: .unauthorized), current: snap(0.5), threshold: 0.2)
        #expect(back.map(\.kind) == [.proxyRecovered(cpaConfig.id)])
    }
}

@Suite("Monitor")
struct MonitorTests {
    /// Routes by host to the two captured testbeds.
    func http() -> StubHTTP {
        let cpa = cpaTestbed(), nine = nineTestbed()
        return StubHTTP { req in
            let target: StubHTTP = req.url!.host == "cpa.test" ? cpa : nine
            return try target.handler(req)
        }
    }

    @Test func refreshesEnabledProxiesInConfigOrder() async {
        let secrets = InMemorySecretStore([cpaConfig.id: "mgmt", nineConfig.id: "pw"])
        var disabled = ProxyConfig(name: "off", kind: .cliProxyAPI, baseURL: URL(string: "http://off.test")!)
        disabled.isEnabled = false
        let snap = await Monitor(http: http()).refresh([nineConfig, disabled, cpaConfig], secrets: secrets)
        #expect(snap.proxies.map(\.name) == ["Testbed 9Router", "Testbed CPA"])
        #expect(snap.proxies.allSatisfy { $0.health.isOK })
    }

    @Test func reusesNineRouterSessionUntilSecretChanges() async throws {
        let stub = http()
        let secrets = InMemorySecretStore([nineConfig.id: "pw"])
        let monitor = Monitor(http: stub)
        _ = await monitor.refresh([nineConfig], secrets: secrets)
        _ = await monitor.refresh([nineConfig], secrets: secrets)
        #expect(stub.requests.filter { $0.path == "/api/auth/login" }.count == 1)
        try secrets.setSecret("wrong", for: nineConfig.id)
        let snap = await monitor.refresh([nineConfig], secrets: secrets)
        #expect(snap.proxies.first?.health == .unauthorized)
    }
}

@Suite("Keychain")
struct KeychainTests {
    @Test func setReadReplaceRemove() throws {
        let store = KeychainSecretStore(service: "dev.motas.tests.\(UUID().uuidString)")
        let id = UUID()
        #expect(try store.secret(for: id) == nil)
        try store.setSecret("first", for: id)
        try store.setSecret("second", for: id)
        #expect(try store.secret(for: id) == "second")
        try store.setSecret(nil, for: id)
        #expect(try store.secret(for: id) == nil)
    }
}
