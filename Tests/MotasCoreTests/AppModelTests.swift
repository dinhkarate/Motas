import Foundation
import Testing
@testable import MotasCore
@testable import MotasUI

final class RecordingNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _delivered: [QuotaAlert] = []
    var delivered: [QuotaAlert] { lock.withLock { _delivered } }
    func deliver(_ alerts: [QuotaAlert]) async { lock.withLock { _delivered += alerts } }
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
        return StubHTTP { req in try (req.url!.host == "cpa.test" ? cpa : nine).handler(req) }
    }

    func model(http: StubHTTP? = nil, secrets: InMemorySecretStore = .init(), notifier: RecordingNotifier = .init()) -> AppModel {
        AppModel(paths: paths, secrets: secrets, http: http ?? testbeds(), notifier: notifier, autoRefresh: false)
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
        try m.save(cpaConfig, secret: "mgmt")
        try m.save(nineConfig, secret: "pw")
        await m.refresh()

        #expect(try secrets.secret(for: cpaConfig.id) == "mgmt")
        let saved = try String(contentsOf: paths.settings, encoding: .utf8)
        #expect(!saved.contains("mgmt") && !saved.contains("\"pw\""))
        #expect(m.snapshot.proxies.map(\.name) == ["Testbed CPA", "Testbed 9Router"])
        #expect(m.headline?.provider == .codex)
        #expect(m.headline?.reserve == 0)
    }

    @Test func savingWithoutSecretKeepsStoredOne() throws {
        let secrets = InMemorySecretStore()
        let m = model(secrets: secrets)
        try m.save(cpaConfig, secret: "mgmt")
        var renamed = cpaConfig
        renamed.name = "Renamed"
        try m.save(renamed, secret: nil)
        #expect(try secrets.secret(for: cpaConfig.id) == "mgmt")
        #expect(m.settings.proxies.map(\.name) == ["Renamed"])
    }

    @Test func removingProxyDeletesItsSecret() throws {
        let secrets = InMemorySecretStore()
        let m = model(secrets: secrets)
        try m.save(cpaConfig, secret: "mgmt")
        try m.remove(cpaConfig.id)
        #expect(m.settings.proxies.isEmpty)
        #expect(try secrets.secret(for: cpaConfig.id) == nil)
    }

    @Test func settingsSurviveRelaunchAndStaleSnapshotIsShownUntilRefresh() async throws {
        let secrets = InMemorySecretStore()
        let first = model(secrets: secrets)
        try first.save(cpaConfig, secret: "mgmt")
        await first.refresh()

        let second = model(secrets: secrets)
        #expect(second.settings.proxies == [cpaConfig])
        #expect(second.snapshot.proxies.first?.accounts.count == 2)   // last real snapshot
        #expect(second.history.isEmpty == false)
    }

    @Test func removedProxyDisappearsFromRestoredSnapshot() async throws {
        let secrets = InMemorySecretStore()
        let first = model(secrets: secrets)
        try first.save(cpaConfig, secret: "mgmt")
        await first.refresh()
        try first.remove(cpaConfig.id)
        #expect(model(secrets: secrets).snapshot.proxies.isEmpty)
    }

    @Test func corruptSettingsAreReportedAndLeftUntouched() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: paths.settings)
        let m = model()
        #expect(m.appError?.contains("settings.json") == true)
        #expect(try Data(contentsOf: paths.settings) == Data("{broken".utf8))
    }

    @Test func keychainApprovalNeverBlocksBackgroundRefresh() async throws {
        let http = testbeds()
        let secrets = InMemorySecretStore([cpaConfig.id: "mgmt"], needingApproval: [cpaConfig.id])
        let m = model(http: http, secrets: secrets)
        try m.update { $0.proxies = [cpaConfig] }
        await m.refresh()
        #expect(m.snapshot.proxies.first?.health == .needsKeychainAccess)
        #expect(m.needsKeychainAccess)
        #expect(http.requests.isEmpty)            // no request without a credential
        #expect(m.hasSecret(for: cpaConfig.id))    // settings can tell a secret exists

        await m.approveKeychainAccess()
        #expect(m.snapshot.proxies.first?.health == .ok)
        #expect(!m.needsKeychainAccess)
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
        try m.save(cpaConfig, secret: "mgmt")
        await m.refresh()
        #expect(notifier.delivered.isEmpty)       // first refresh never alerts
        down.value = true
        await m.refresh()
        #expect(notifier.delivered.map(\.kind) == [.proxyDown(cpaConfig.id)])
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
