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

/// The refresh timer's waits. Each one is announced on `started` and lasts
/// until `fire()`, or until its task is cancelled, which `cancelled` counts at once.
final class Sleeps: @unchecked Sendable {
    let started: AsyncStream<Duration>
    private let announce: AsyncStream<Duration>.Continuation
    private let lock = NSLock()
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    private var _cancelled = 0

    init() { (started, announce) = AsyncStream.makeStream() }

    var cancelled: Int { lock.withLock { _cancelled } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    waiting.append((id, continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) } else { announce.yield(duration) }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                _cancelled += 1
                return waiting.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest wait, as if its time had come.
    func fire() {
        let continuation = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst().continuation }
        continuation?.resume()
    }
}

/// What `router` serves: Codex accounts by id, each with a plan and the
/// percent left, or one reply to everything.
final class RouterState: @unchecked Sendable {
    typealias Account = (plan: String, percent: Int)
    private let lock = NSLock()
    private var _accounts: [String: Account]
    private var _failure: StubHTTP.Reply?

    init(_ accounts: [String: Account]) { _accounts = accounts }

    var accounts: [String: Account] {
        get { lock.withLock { _accounts } }
        set { lock.withLock { _accounts = newValue } }
    }

    var failure: StubHTTP.Reply? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
}

let routerConfig = ProxyConfig(name: "Router", kind: .nineRouter, baseURL: URL(string: "http://router.local")!)

/// A 9Router behind its CLI token (`productionToken`), serving `state`.
func router(_ state: RouterState) -> StubHTTP {
    nineServer(tokens: [productionToken]) { req in
        if let failure = state.failure { return failure }
        let accounts = state.accounts
        if req.path == "/api/providers" {
            let connections = accounts.keys.sorted().map {
                ["id": $0, "provider": "codex", "email": "\($0)@example.com", "isActive": true] as [String: Any]
            }
            return (200, try JSONSerialization.data(withJSONObject: ["connections": connections]), [:])
        }
        guard let account = accounts[String(req.path.dropFirst("/api/usage/".count))] else { return (404, Data(), [:]) }
        let session: [String: Any] = ["total": 100, "used": 100 - account.percent, "resetAt": "2026-12-01T00:00:00.000Z"]
        return (200, try JSONSerialization.data(withJSONObject: ["plan": account.plan, "quotas": ["session": session]]), [:])
    }
}

/// Builds `AppModel`s on a temporary directory, preferences suite and clock,
/// recording the timer's waits, widget reloads and activations.
@MainActor
final class Harness {
    let dir = tempURL("app")
    let now = TestNow()
    let sleeps = Sleeps()
    let notifier = RecordingNotifier()
    let preferences: UIPreferences
    var reloads = 0
    var activations = 0

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A suite named by a path is a plist of its own, never the app's domain.
        preferences = UIPreferences(defaults: UserDefaults(suiteName: dir.appendingPathComponent("preferences").path)!)
    }

    var paths: AppModel.Paths {
        AppModel.Paths(settings: dir.appendingPathComponent("settings.json"), history: dir.appendingPathComponent("history.json"),
                       snapshot: dir.appendingPathComponent("snapshot.json"))
    }

    var settings: SettingsStore { SettingsStore(url: paths.settings) }

    /// `widget`: as if run from Motas.app, so widget reloads are counted.
    func model(http: StubHTTP, secrets: any SecretStore = InMemorySecretStore(), widget: Bool = false) -> AppModel {
        let sleeps = sleeps
        var reload: (@MainActor () -> Void)?
        if widget { reload = { self.reloads += 1 } }
        return AppModel(AppEnvironment(paths: paths, secrets: secrets, http: http, notifier: notifier, preferences: preferences,
                                       now: now.function, sleep: { try await sleeps.sleep($0) }, reloadWidget: reload,
                                       activate: { self.activations += 1 }))
    }
}

@MainActor
@Suite("App model", .timeLimit(.minutes(1)))
struct AppModelTests {
    let h = Harness()

    func testbeds() -> StubHTTP {
        let cpa = cpaTestbed(), nine = nineTestbed()
        return StubHTTP { req in try (req.url!.host == "cpa.local" ? cpa : nine).handler(req) }
    }

    /// A model launched with `settings` saved (by default `routerConfig`) and the router's token stored.
    func routerModel(_ state: RouterState, settings: MotasSettings = MotasSettings(proxies: [routerConfig]), widget: Bool = false,
                     secrets: TestSecrets = TestSecrets([routerConfig.id: productionToken])) throws -> (AppModel, StubHTTP) {
        try h.settings.save(settings)
        let http = router(state)
        return (h.model(http: http, secrets: secrets, widget: widget), http)
    }

    func usageReads(_ http: StubHTTP) -> [String?] { http.requests.filter { $0.path.hasPrefix("/api/usage/") }.map { $0.url?.query } }

    @Test func unconfiguredShowsEmptyStateAndMakesNoRequests() async {
        let http = testbeds()
        let m = h.model(http: http)
        await m.refresh(force: false, reason: "test").value
        #expect(!m.isConfigured)
        #expect(m.snapshot.proxies.isEmpty && m.pools.isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test func addingProxiesStoresSecretsInKeychainAndShowsRealAccounts() async throws {
        let secrets = InMemorySecretStore()
        let m = h.model(http: testbeds(), secrets: secrets)
        try await m.save(cpaConfig, secret: "mgmt")
        try await m.save(nineConfig, secret: "pw")
        await m.refresh(force: false, reason: "test").value

        #expect(try secrets.secret(for: cpaConfig.id) == "mgmt")
        #expect(h.activations == 2)    // in front, for any Keychain prompt
        let saved = try String(contentsOf: h.paths.settings, encoding: .utf8)
        #expect(!saved.contains("mgmt") && !saved.contains("\"pw\""))
        #expect(m.snapshot.proxies.map(\.name) == ["Testbed CPA", "Testbed 9Router"])
        // CPA's and 9Router's Codex Free accounts are one pool, in one 30-day lane.
        #expect(m.headline?.id == "codex|free|")
        #expect(m.headline?.members == 2 && m.headline?.reserve == 0)
        #expect(m.headline?.lanes.map(\.label) == ["30-day"])
        #expect(SharedSnapshot.load(from: h.paths.snapshot)?.headlineID == "codex|free|")
    }

    @Test func savingWithoutSecretKeepsStoredOne() async throws {
        let secrets = InMemorySecretStore()
        let m = h.model(http: testbeds(), secrets: secrets)
        try await m.save(cpaConfig, secret: "mgmt")
        var renamed = cpaConfig
        renamed.name = "Renamed"
        try await m.save(renamed, secret: nil)
        #expect(try secrets.secret(for: cpaConfig.id) == "mgmt")
        #expect(m.settings.proxies.map(\.name) == ["Renamed"])
    }

    @Test func savingKeepsAProxyTheCLIAdded() async throws {
        let m = h.model(http: testbeds())
        try await m.save(cpaConfig, secret: nil)
        try h.settings.update { $0.proxies.append(nineConfig) }
        var renamed = cpaConfig
        renamed.name = "Renamed"
        try await m.save(renamed, secret: nil)
        #expect(m.settings.proxies.map(\.name) == ["Renamed", "Testbed 9Router"])
        #expect(try h.settings.load() == m.settings)
    }

    @Test func removingProxyDeletesItsSecret() async throws {
        let secrets = InMemorySecretStore()
        let m = h.model(http: testbeds(), secrets: secrets)
        try await m.save(cpaConfig, secret: "mgmt")
        #expect(m.secretPresence == .known([cpaConfig.id]))
        try await m.remove(cpaConfig.id)
        #expect(m.secretPresence == .known([]))
        #expect(m.settings.proxies.isEmpty)
        #expect(try secrets.secret(for: cpaConfig.id) == nil)
    }

    @Test func settingsSurviveRelaunchAndStaleSnapshotIsShownUntilRefresh() async throws {
        let secrets = InMemorySecretStore()
        let first = h.model(http: testbeds(), secrets: secrets)
        try await first.save(cpaConfig, secret: "mgmt")
        await first.refresh(force: false, reason: "test").value

        let second = h.model(http: testbeds(), secrets: secrets)
        #expect(second.settings.proxies == [cpaConfig])
        #expect(second.snapshot.proxies.first?.accounts.count == 2)   // last real snapshot
        #expect(second.history.isEmpty == false)
    }

    @Test func removedProxyDisappearsFromRestoredSnapshot() async throws {
        let secrets = InMemorySecretStore()
        let first = h.model(http: testbeds(), secrets: secrets)
        try await first.save(cpaConfig, secret: "mgmt")
        await first.refresh(force: false, reason: "test").value
        try await first.remove(cpaConfig.id)
        #expect(h.model(http: testbeds(), secrets: secrets).snapshot.proxies.isEmpty)
    }

    @Test func corruptSettingsShowABannerAndAreNeverWritten() async throws {
        try Data("{broken".utf8).write(to: h.paths.settings)
        let secrets = InMemorySecretStore()
        let m = h.model(http: testbeds(), secrets: secrets)
        #expect(m.settingsError?.hasPrefix("settings.json is unreadable: ") == true)
        await #expect(throws: DecodingError.self) { try await m.save(cpaConfig, secret: "mgmt") }
        #expect(try secrets.secret(for: cpaConfig.id) == nil)    // settings come first
        #expect(throws: DecodingError.self) { try m.update { $0.lowReserveThreshold = 0.5 } }
        await m.reloadAfterExternalChange()
        #expect(m.settingsError != nil && m.settings == MotasSettings())
        #expect(try Data(contentsOf: h.paths.settings) == Data("{broken".utf8))

        // Repaired by hand: the next reload adopts it and drops the banner.
        try h.settings.save(MotasSettings(proxies: [cpaConfig]))
        await m.reloadAfterExternalChange()
        #expect(m.settingsError == nil && m.settings.proxies == [cpaConfig])
    }

    @Test func keychainApprovalNeverBlocksBackgroundRefresh() async throws {
        let http = testbeds()
        let secrets = InMemorySecretStore([cpaConfig.id: "mgmt"], needingApproval: true)
        try h.settings.save(MotasSettings(proxies: [cpaConfig]))
        let m = h.model(http: http, secrets: secrets)
        await m.refresh(force: false, reason: "test").value
        #expect(m.snapshot.proxies.first?.health == .needsKeychainAccess)
        #expect(m.needsKeychainAccess)
        #expect(http.requests.isEmpty)            // no request without a credential
        #expect(m.secretPresence == .locked && !m.hasSecret(for: cpaConfig.id))    // nobody knows until approved

        await m.approveKeychain()
        #expect(h.activations == 1)               // the prompt comes to the front
        #expect(m.snapshot.proxies.first?.health == .ok)
        #expect(!m.needsKeychainAccess)
        #expect(m.secretPresence == .known([cpaConfig.id]) && m.hasSecret(for: cpaConfig.id))
    }

    @Test func oneApprovalAtATime() async {
        let secrets = TestSecrets()
        secrets.error = SecretStoreError.needsApproval
        let m = h.model(http: router(RouterState([:])), secrets: secrets)
        let first = Task { await m.approveKeychain() }
        let second = Task { await m.approveKeychain() }
        await first.value
        await second.value
        #expect(secrets.approvals == 1 && h.activations == 1)
    }

    @Test func notifiesWhenProxyGoesDown() async throws {
        let down = Flag()
        let up = testbeds()
        let http = StubHTTP { req in
            if down.value { throw URLError(.timedOut) }
            return try up.handler(req)
        }
        let m = h.model(http: http)
        try await m.save(cpaConfig, secret: "mgmt")
        func refresh() async {
            await m.refresh(force: false, reason: "test").value
            await m.delivery?.value
        }
        await refresh()
        #expect(h.notifier.delivered.isEmpty)       // first refresh never alerts
        down.value = true
        await refresh()
        #expect(h.notifier.delivered.isEmpty)       // one failed refresh is a blip
        await refresh()
        #expect(h.notifier.delivered.map(\.identifier) == ["proxyDown:\(cpaConfig.id.uuidString)"])
        await refresh()
        #expect(h.notifier.delivered.count == 1)    // staying down does not re-alert
    }

    // MARK: Triggers

    /// Three requests while none runs: one runs, the other two merge into one
    /// queued behind it, which stays forced because one of them was.
    @Test func overlappingRefreshesRunOnceMore() async throws {
        let (m, http) = try routerModel(RouterState(["a": ("plus", 80)]))
        let first = m.refresh(force: false, reason: "test")
        let second = m.refresh(force: true, reason: "test")
        let third = m.refresh(force: false, reason: "test")
        #expect(second == first && third == first && m.isRefreshing)
        await first.value
        #expect(m.running == nil && !m.isRefreshing)
        #expect(http.requests.filter { $0.path == "/api/providers" }.count == 2)
        #expect(usageReads(http) == [nil, "force=1"])
    }

    @Test func onlyAChangeOfProxiesRefreshes() async throws {
        let http = router(RouterState(["a": ("plus", 80)]))
        let m = h.model(http: http, secrets: TestSecrets([routerConfig.id: productionToken]))
        try m.update { $0.proxies = [routerConfig] }
        let refresh = try #require(m.running)
        await refresh.value
        #expect(m.pools.map(\.reserve) == [0.8])
        #expect(usageReads(http) == [nil])          // not forced

        // Past the stale limit, recomputed pools show the figures as unknown, without a read.
        let requests = http.requests.count
        h.now.advance(3600)
        try m.update { $0.lowReserveThreshold = 0.5 }
        #expect(m.running == nil && m.pools.map(\.reserve) == [nil])
        try m.update { $0.notificationsEnabled = false }
        #expect(m.running == nil && http.requests.count == requests)
    }

    @Test func uiPreferencesNeverRefreshNorTouchSettings() throws {
        let (m, http) = try routerModel(RouterState(["a": ("plus", 80)]))
        let saved = try Data(contentsOf: h.paths.settings)
        m.menuBarPool = "codex|plus|"
        m.desktopWidgetEnabled = true
        m.desktopWidgetLocked = true
        m.desktopWidgetCards = ["codex|plus|"]
        m.onboardingDone = true
        #expect(m.running == nil && http.requests.isEmpty)
        #expect(try Data(contentsOf: h.paths.settings) == saved)
        #expect(h.preferences.menuBarPool == "codex|plus|" && h.preferences.desktopWidgetCards == ["codex|plus|"])
        #expect(h.preferences.desktopWidgetEnabled && h.preferences.desktopWidgetLocked && h.preferences.onboardingDone)

        let relaunched = h.model(http: http)
        #expect(relaunched.menuBarPool == "codex|plus|" && relaunched.desktopWidgetCards == ["codex|plus|"])
        #expect(relaunched.desktopWidgetEnabled && relaunched.desktopWidgetLocked && relaunched.onboardingDone)
    }

    @Test func aNewIntervalRestartsTheTimer() async throws {
        let m = h.model(http: router(RouterState([:])))
        defer { m.stop() }
        var waits = h.sleeps.started.makeAsyncIterator()
        m.start()
        #expect(await waits.next() == .seconds(300))
        try m.update { $0.lowReserveThreshold = 0.5 }
        #expect(h.sleeps.cancelled == 0)            // other settings leave the wait alone
        try m.update { $0.refreshInterval = 120 }
        #expect(h.sleeps.cancelled == 1)
        #expect(await waits.next() == .seconds(120))
        h.sleeps.fire()                             // a timer refresh, then the next wait
        #expect(await waits.next() == .seconds(120))
    }

    @Test func openingThePanelRefreshesOnlyAnOldSnapshot() async throws {
        let (m, _) = try routerModel(RouterState(["a": ("plus", 80)]))
        await m.refresh(force: false, reason: "test").value
        h.now.advance(150)                          // max(120 s, 300 s / 2)
        #expect(m.panelOpened() == nil)
        h.now.advance(1)
        let refresh = try #require(m.panelOpened())
        await refresh.value
        #expect(m.snapshot.fetchedAt == h.now.date)
    }

    @Test func aWakeRefreshesTenSecondsLater() async throws {
        let (m, http) = try routerModel(RouterState(["a": ("plus", 80)]))
        var waits = h.sleeps.started.makeAsyncIterator()
        let wake = Task { await m.wake() }
        #expect(await waits.next() == .seconds(10))
        #expect(http.requests.isEmpty)
        h.sleeps.fire()
        await wake.value
        #expect(usageReads(http) == [nil])
    }

    /// What `motas proxy add` does while the app runs: settings.json, the
    /// Keychain item, then the notice.
    @Test func anExternalChangeReloadsSettingsAndSecrets() async throws {
        let secrets = TestSecrets()
        let http = router(RouterState(["a": ("plus", 80)]))
        let m = h.model(http: http, secrets: secrets)
        try h.settings.update { $0.proxies = [routerConfig] }
        try await secrets.setSecret(productionToken, for: routerConfig.id)
        await m.reloadAfterExternalChange()
        #expect(m.settings.proxies == [routerConfig])
        #expect(secrets.invalidations == 1)
        #expect(m.secretPresence == .known([routerConfig.id]))
        #expect(m.snapshot.proxies.first?.health == .ok)
        #expect(usageReads(http) == [nil])          // not forced
    }

    // MARK: Saving a proxy

    @Test func aSecretThatCannotBeStoredLeavesTheProxySaved() async throws {
        let secrets = TestSecrets()
        secrets.writeError = SecretStoreError.needsApproval
        let m = h.model(http: router(RouterState(["a": ("plus", 80)])), secrets: secrets)
        await #expect(throws: ProxySaveError.keychainNotUpdated("access was not allowed")) {
            try await m.save(routerConfig, secret: productionToken)
        }
        #expect(try h.settings.load().proxies == [routerConfig] && m.settings.proxies == [routerConfig])
        #expect(secrets.invalidations == 1 && h.activations == 1)
        await m.running?.value
        #expect(m.snapshot.proxies.first?.health == .failed(.missingCredential))
    }

    @Test func aNewServerNeedsANewSecret() async throws {
        let secrets = TestSecrets()
        let m = h.model(http: router(RouterState(["a": ("plus", 80)])), secrets: secrets)
        try await m.save(routerConfig, secret: productionToken)
        var moved = routerConfig
        moved.baseURL = URL(string: "http://other.local")!
        var password = routerConfig
        password.auth = .password
        await #expect(throws: ProxySaveError.newSecretRequired) { try await m.save(moved, secret: nil) }
        await #expect(throws: ProxySaveError.newSecretRequired) { try await m.save(password, secret: nil) }
        #expect(try h.settings.load().proxies == [routerConfig] && m.settings.proxies == [routerConfig])

        // Test never sends the stored secret to another server either.
        #expect(await m.test(moved, secret: nil) == .failure(.missingCredential))
        #expect(try await m.test(routerConfig, secret: nil).get().map(\.id) == ["a"])

        try await m.save(moved, secret: "fedcba9876543210")
        #expect(m.settings.proxies == [moved])
        #expect(try secrets.secret(for: moved.id) == "fedcba9876543210")
    }

    // MARK: After a refresh

    @Test func theWidgetReloadsWhenItChangesAtMostEveryQuarterHour() async throws {
        let state = RouterState(["a": ("plus", 80), "b": ("pro", 60)])
        let (m, _) = try routerModel(state, widget: true)
        func refresh() async { await m.refresh(force: false, reason: "test").value }
        await refresh()
        #expect(h.reloads == 1)
        await refresh()
        #expect(h.reloads == 1)                     // nothing changed
        state.accounts["a"] = ("plus", 70)
        h.now.advance(60)
        await refresh()
        #expect(h.reloads == 1)                     // changed, but within 15 min of the last reload
        h.now.advance(15 * 60)
        await refresh()
        #expect(h.reloads == 2)

        #expect(m.headline?.id == "codex|pro|")
        m.menuBarPool = "codex|plus|"
        await refresh()
        #expect(h.reloads == 3)                     // a new headline does not wait
        state.failure = sessionRejected
        await refresh()
        #expect(h.reloads == 4)                     // nor does a proxy problem
    }

    @Test func widgetKitIsReloadedOnlyFromAnAppBundle() throws {
        #expect(AppEnvironment.widgetReloader(in: .main) == nil)    // the test runner
        let app = tempURL("Test.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.motas.test"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(AppEnvironment.widgetReloader(in: try #require(Bundle(url: app))) != nil)
    }

    @Test func offlineTheHeaderSaysSoAndNoProxyIsDown() async throws {
        let state = RouterState(["a": ("plus", 80)])
        let (m, _) = try routerModel(state)
        func refresh() async {
            await m.refresh(force: false, reason: "test").value
            await m.delivery?.value
        }
        await refresh()
        #expect(m.headerStatus == .updated(h.now.date))
        m.isOnline = false
        #expect(m.headerStatus == .offline)
        state.failure = (500, Data(), [:])
        for _ in 0..<3 { await refresh() }
        #expect(m.snapshot.proxies.first?.consecutiveFailures == 3)
        #expect(h.notifier.delivered.isEmpty)
        m.isOnline = true
        await refresh()
        #expect(h.notifier.delivered.map(\.kind) == [.proxyDown])
    }

    @Test func nothingIsPostedWhileNotificationsAreOff() async throws {
        let state = RouterState(["a": ("plus", 80)])
        let (m, _) = try routerModel(state, settings: MotasSettings(proxies: [routerConfig], notificationsEnabled: false))
        await m.refresh(force: false, reason: "test").value
        state.failure = (500, Data(), [:])
        for _ in 0..<3 { await m.refresh(force: false, reason: "test").value }
        #expect(m.delivery == nil && h.notifier.delivered.isEmpty)
    }

    @Test func clickingAnAlertOpensWhatItIsAbout() {
        let low = QuotaAlert(kind: .poolLow, key: "codex|plus|", title: "Codex Plus is low", body: "", poolID: "codex|plus|")
        let down = QuotaAlert(kind: .proxyDown, key: routerConfig.id.uuidString, title: "Router unavailable", body: "",
                              proxyID: routerConfig.id)
        let back = QuotaAlert(kind: .proxyBack, key: routerConfig.id.uuidString, title: "Router is back", body: "", proxyID: routerConfig.id)
        let rejected = QuotaAlert(kind: .accountsRejected, key: cpaConfig.id.uuidString, title: "1 account on Testbed CPA needs re-login",
                                  body: "", proxyID: cpaConfig.id)
        #expect(SystemNotifier.userInfo(low) == ["kind": "poolLow", "poolID": "codex|plus|"])
        #expect(SystemNotifier.userInfo(down) == ["kind": "proxyDown", "proxyID": routerConfig.id.uuidString])

        let proxies = [routerConfig, cpaConfig]
        func click(_ alert: QuotaAlert, _ proxies: [ProxyConfig]) -> AlertClick { AlertClick(SystemNotifier.userInfo(alert), proxies: proxies) }
        #expect(click(down, proxies) == .dashboard(URL(string: "http://router.local/dashboard")!))
        #expect(click(rejected, proxies) == .dashboard(URL(string: "http://cpa.local:8317")!))
        #expect(click(low, proxies) == .panel && click(back, proxies) == .panel)
        #expect(click(down, []) == .panel)          // a proxy removed since
        #expect(nineConfig.dashboardURL.absoluteString == "http://9r.local:20128/dashboard")
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
