import Foundation
import Testing
@testable import MotasCore
@testable import MotasUI

final class RecordingNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _delivered: [QuotaAlert] = []
    var delivered: [QuotaAlert] { lock.withLock { _delivered } }
    func deliver(_ alerts: [QuotaAlert]) async -> NotificationDelivery {
        lock.withLock { _delivered += alerts }
        return .delivered
    }
}

@MainActor
@Suite("App model")
struct AppModelTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("motas-app-\(UUID().uuidString)")
    var paths: AppModel.Paths {
        AppModel.Paths(settings: dir.appendingPathComponent("settings.json"),
                       history: dir.appendingPathComponent("history.json"),
                       snapshot: dir.appendingPathComponent("snapshot.json"))
    }

    func testbeds() -> StubHTTP {
        let cpa = cpaTestbed(), nine = nineTestbed()
        return StubHTTP { req in try (req.url!.host == "cpa.local" ? cpa : nine).handler(req) }
    }

    /// A plist in `dir` (a suite named by a path), never the app's domain.
    var preferences: UIPreferences { UIPreferences(defaults: UserDefaults(suiteName: dir.appendingPathComponent("preferences").path)!) }

    func model(http: StubHTTP? = nil, secrets: InMemorySecretStore = .init(), notifier: RecordingNotifier = .init()) -> AppModel {
        AppModel(paths: paths, secrets: secrets, http: http ?? testbeds(), notifier: notifier, preferences: preferences,
                 autoRefresh: false)
    }

    @Test func unconfiguredShowsEmptyStateAndMakesNoRequests() async {
        let http = testbeds()
        let m = model(http: http)
        await m.refresh()
        #expect(!m.isConfigured)
        #expect(m.snapshot.proxies.isEmpty)
        #expect(m.pools.isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test func addingProxiesStoresSecretsInKeychainAndShowsRealAccounts() async throws {
        let secrets = InMemorySecretStore()
        let m = model(secrets: secrets)
        try await m.save(cpaConfig, secret: "mgmt")
        try await m.save(nineConfig, secret: "pw")
        await m.refresh()

        #expect(try secrets.secret(for: cpaConfig.id) == "mgmt")
        let saved = try String(contentsOf: paths.settings, encoding: .utf8)
        #expect(!saved.contains("mgmt") && !saved.contains("\"pw\""))
        #expect(m.snapshot.proxies.map(\.name) == ["Testbed CPA", "Testbed 9Router"])
        // CPA's and 9Router's Codex Free accounts are one pool, in one 30-day lane.
        #expect(m.headline?.id == "codex|free|")
        #expect(m.headline?.members == 2 && m.headline?.reserve == 0)
        #expect(m.headline?.lanes.map(\.label) == ["30-day"])
        #expect(SharedSnapshot.load(from: paths.snapshot)?.headlineID == "codex|free|")
    }

    @Test func savingWithoutSecretKeepsStoredOne() async throws {
        let secrets = InMemorySecretStore()
        let m = model(secrets: secrets)
        try await m.save(cpaConfig, secret: "mgmt")
        var renamed = cpaConfig
        renamed.name = "Renamed"
        try await m.save(renamed, secret: nil)
        #expect(try secrets.secret(for: cpaConfig.id) == "mgmt")
        #expect(m.settings.proxies.map(\.name) == ["Renamed"])
    }

    @Test func savingKeepsAProxyTheCLIAdded() async throws {
        let m = model()
        try await m.save(cpaConfig, secret: nil)
        try SettingsStore(url: paths.settings).update { $0.proxies.append(nineConfig) }
        var renamed = cpaConfig
        renamed.name = "Renamed"
        try await m.save(renamed, secret: nil)
        #expect(m.settings.proxies.map(\.name) == ["Renamed", "Testbed 9Router"])
        #expect(try SettingsStore(url: paths.settings).load() == m.settings)
    }

    @Test func removingProxyDeletesItsSecret() async throws {
        let secrets = InMemorySecretStore()
        let m = model(secrets: secrets)
        try await m.save(cpaConfig, secret: "mgmt")
        #expect(m.secretPresence == .known([cpaConfig.id]))
        try await m.remove(cpaConfig.id)
        #expect(m.secretPresence == .known([]))
        #expect(m.settings.proxies.isEmpty)
        #expect(try secrets.secret(for: cpaConfig.id) == nil)
    }

    @Test func settingsSurviveRelaunchAndStaleSnapshotIsShownUntilRefresh() async throws {
        let secrets = InMemorySecretStore()
        let first = model(secrets: secrets)
        try await first.save(cpaConfig, secret: "mgmt")
        await first.refresh()

        let second = model(secrets: secrets)
        #expect(second.settings.proxies == [cpaConfig])
        #expect(second.snapshot.proxies.first?.accounts.count == 2)   // last real snapshot
        #expect(second.history.isEmpty == false)
    }

    @Test func removedProxyDisappearsFromRestoredSnapshot() async throws {
        let secrets = InMemorySecretStore()
        let first = model(secrets: secrets)
        try await first.save(cpaConfig, secret: "mgmt")
        await first.refresh()
        try await first.remove(cpaConfig.id)
        #expect(model(secrets: secrets).snapshot.proxies.isEmpty)
    }

    @Test func corruptSettingsAreReportedAndLeftUntouched() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: paths.settings)
        let m = model()
        #expect(m.appError?.contains("settings.json") == true)
        await #expect(throws: (any Error).self) { try await m.save(cpaConfig, secret: nil) }
        #expect(m.settings.proxies.isEmpty)
        #expect(try Data(contentsOf: paths.settings) == Data("{broken".utf8))
    }

    @Test func keychainApprovalNeverBlocksBackgroundRefresh() async throws {
        let http = testbeds()
        let secrets = InMemorySecretStore([cpaConfig.id: "mgmt"], needingApproval: true)
        let m = model(http: http, secrets: secrets)
        try m.update { $0.proxies = [cpaConfig] }
        await m.refresh()
        #expect(m.snapshot.proxies.first?.health == .needsKeychainAccess)
        #expect(m.needsKeychainAccess)
        #expect(http.requests.isEmpty)            // no request without a credential
        #expect(m.secretPresence == .locked && !m.hasSecret(for: cpaConfig.id))    // nobody knows until approved

        await m.approveKeychainAccess()
        #expect(m.snapshot.proxies.first?.health == .ok)
        #expect(!m.needsKeychainAccess)
        #expect(m.secretPresence == .known([cpaConfig.id]) && m.hasSecret(for: cpaConfig.id))
    }

    @Test func notifiesWhenProxyGoesDown() async throws {
        let notifier = RecordingNotifier()
        let down = Flag()
        let up = testbeds()
        let http = StubHTTP { req in
            if down.value { throw URLError(.timedOut) }
            return try up.handler(req)
        }
        let m = model(http: http, notifier: notifier)
        try await m.save(cpaConfig, secret: "mgmt")
        await m.refresh()
        #expect(notifier.delivered.isEmpty)       // first refresh never alerts
        down.value = true
        await m.refresh()
        #expect(notifier.delivered.isEmpty)       // one failed refresh is a blip
        await m.refresh()
        #expect(notifier.delivered.map(\.identifier) == ["proxyDown:\(cpaConfig.id.uuidString)"])
        await m.refresh()
        #expect(notifier.delivered.count == 1)    // staying down does not re-alert
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
