import AppKit
import Foundation
import MotasCore
import Network
import ServiceManagement
import SwiftUI
import WidgetKit

public protocol Notifier: Sendable {
    @discardableResult
    func deliver(_ alerts: [QuotaAlert]) async -> NotificationDelivery
}

/// What `AppModel` reads, writes and calls: the user's (`live`), or a test's.
/// The defaults are inert: no widget reload, no activation, nothing observed.
struct AppEnvironment {
    var paths: AppModel.Paths
    var secrets: any SecretStore
    var http: any HTTPClient
    var notifier: any Notifier
    var preferences: UIPreferences
    var now: @Sendable () -> Date = Date.init
    /// The refresh timer's wait and the delay after wake.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Reloads the WidgetKit widget; nil outside an app bundle.
    var reloadWidget: (@MainActor () -> Void)?
    /// Brings Motas to the front, so a Keychain prompt does not open behind other windows.
    var activate: @MainActor () -> Void = {}
    /// Starts watching the network, wake and the CLI's changes; what it returns keeps that going.
    var observe: @MainActor (AppModel) -> [AnyObject] = { _ in [] }

    /// The user's files, Keychain item, network and UserDefaults.
    @MainActor static var live: AppEnvironment {
        let preferences = UIPreferences()
        return AppEnvironment(paths: .standard, secrets: KeychainSecretStore(preferences: preferences), http: URLSessionHTTPClient(),
                              notifier: SystemNotifier(), preferences: preferences, reloadWidget: widgetReloader(in: .main),
                              activate: { NSApplication.shared.activate(ignoringOtherApps: true) }, observe: AppModel.observeSystem)
    }

    /// WidgetKit knows the widget only when Motas runs from its app bundle.
    static func widgetReloader(in bundle: Bundle) -> (@MainActor () -> Void)? {
        guard bundle.isAppBundle else { return nil }
        return { WidgetCenter.shared.reloadTimelines(ofKind: "dev.motas.pool") }
    }
}

extension Bundle {
    /// Run from Motas.app, which Notification Center and WidgetKit need; not
    /// from `swift run`, the Homebrew symlink or tests.
    var isAppBundle: Bool { bundleIdentifier != nil && bundleURL.pathExtension == "app" }
}

/// What the panel header says: "Offline", or when the data was read.
public enum HeaderStatus: Equatable {
    case offline
    case updated(Date)
}

/// Why `AppModel.save` or `remove` did not finish.
public enum ProxySaveError: Error, Equatable, CustomStringConvertible {
    /// The kind, URL or sign-in changed without a new secret; nothing was saved.
    case newSecretRequired
    /// The settings were saved; Keychain was not updated.
    case keychainNotUpdated(String)

    public var description: String {
        switch self {
        case .newSecretRequired: "Enter the secret again: the type, URL or sign-in changed."
        case .keychainNotUpdated(let reason): "Settings were saved, but Keychain was not updated: \(reason)."
        }
    }
}

/// App state. Everything the UI shows comes from a real `Snapshot`; with no
/// proxies configured the app shows an empty state, never sample data.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var settings: MotasSettings
    @Published public private(set) var snapshot: Snapshot
    @Published public private(set) var pools: [PoolSummary] = []
    @Published public private(set) var history: [PoolSample] = []
    @Published public private(set) var isRefreshing = false
    /// False while the network is down: the header says "Offline" and no
    /// proxy-down alert is sent.
    @Published public internal(set) var isOnline = true
    /// "settings.json is unreadable: …" while it is; it is then never written.
    @Published public private(set) var settingsError: String?
    /// A Keychain error Allow… ran into; a declined prompt is not one.
    @Published public private(set) var secretError: String?
    /// The shared snapshot or history could not be written.
    @Published public private(set) var saveError: String?
    /// Which proxies have a secret, from the store's cache; never read from Keychain itself.
    @Published public private(set) var secretPresence: SecretPresence = .locked

    // UI preferences, kept in UserDefaults: none refreshes or touches settings.json.
    @Published public var menuBarPool: String? = nil { didSet { preferences.menuBarPool = menuBarPool } }
    @Published public var desktopWidgetEnabled = false { didSet { preferences.desktopWidgetEnabled = desktopWidgetEnabled } }
    @Published public var desktopWidgetLocked = false { didSet { preferences.desktopWidgetLocked = desktopWidgetLocked } }
    @Published public var desktopWidgetCards: [String]? = nil { didSet { preferences.desktopWidgetCards = desktopWidgetCards } }
    @Published public var onboardingDone = false { didSet { preferences.onboardingDone = onboardingDone } }
    /// Set by the Keychain store once the 0.2 items are migrated.
    @Published public private(set) var legacyKeychainMigrated = false

    private let environment: AppEnvironment
    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let monitor: Monitor
    private var alerts = AlertEngine()
    /// The refresh in flight. Requests meanwhile merge into `queued`, which
    /// the same task runs next: one in flight plus one queued, forced if any was.
    private(set) var running: Task<Void, Never>?
    private var queued: (force: Bool, reason: StaticString)?
    /// The last notification delivery. It never holds up a refresh: the first
    /// one may wait for the user to answer macOS's permission prompt.
    private(set) var delivery: Task<Void, Never>?
    private var approval: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var observers: [AnyObject] = []
    /// What the widget was last reloaded with, and when.
    private var widgetDigest: WidgetDigest?
    private var widgetReloadAt: Date?

    public struct Paths: Sendable {
        public var settings: URL
        public var history: URL
        public var snapshot: URL

        public static var standard: Paths {
            let dir = SettingsStore.defaultURL.deletingLastPathComponent()
            return Paths(settings: dir.appendingPathComponent("settings.json"),
                         history: dir.appendingPathComponent("history.json"),
                         snapshot: SharedSnapshot.url)
        }
    }

    public convenience init() { self.init(.live) }

    init(_ environment: AppEnvironment) {
        self.environment = environment
        settingsStore = SettingsStore(url: environment.paths.settings)
        historyStore = HistoryStore(url: environment.paths.history)
        var settingsError: String?
        let settings: MotasSettings
        do {
            settings = try settingsStore.load()
        } catch {
            settings = MotasSettings()
            settingsError = Self.unreadable(error)
        }
        // Last real snapshot, shown with its age until the first refresh lands.
        var snapshot = SharedSnapshot.load(from: environment.paths.snapshot).map { $0.snapshot } ?? .empty
        if !settings.proxies.isEmpty {
            snapshot.proxies = snapshot.proxies.filter { p in settings.proxies.contains { $0.id == p.id && $0.isEnabled } }
        } else {
            snapshot = .empty
        }
        self.settings = settings
        self.snapshot = snapshot
        monitor = Monitor(http: environment.http, secrets: environment.secrets, seed: snapshot, now: environment.now)
        pools = Pool.summarize(snapshot, now: environment.now(), staleLimit: settings.staleLimit)
        history = historyStore.load()
        secretPresence = environment.secrets.presence()
        self.settingsError = settingsError
        let preferences = environment.preferences
        menuBarPool = preferences.menuBarPool
        desktopWidgetEnabled = preferences.desktopWidgetEnabled
        desktopWidgetLocked = preferences.desktopWidgetLocked
        desktopWidgetCards = preferences.desktopWidgetCards
        onboardingDone = preferences.onboardingDone
        legacyKeychainMigrated = preferences.legacyKeychainMigrated
    }

    private var secrets: any SecretStore { environment.secrets }
    private var preferences: UIPreferences { environment.preferences }

    public var isConfigured: Bool { settings.proxies.contains(where: \.isEnabled) }
    public var headline: PoolSummary? { Pool.headline(pools, pinned: menuBarPool) }

    public var headerStatus: HeaderStatus? {
        if !isOnline { return .offline }
        return snapshot.fetchedAt > .distantPast ? .updated(snapshot.fetchedAt) : nil
    }

    // MARK: Refresh

    /// Watches the system, refreshes, then starts the timer. The app delegate
    /// calls it once: a MenuBarExtra label's .task never runs.
    public func start() {
        // A background menu bar app gets App Nap, which stretches the refresh
        // timer well past its interval. Opt out (idle system sleep still allowed).
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Monitoring proxy quota")
        }
        observers = environment.observe(self)
        refresh(force: false, reason: "launch")
        startTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Refreshes every interval after the previous refresh ended, so a slow
    /// one (password mode can take two minutes) never piles up.
    private func startTimer() {
        timer?.cancel()
        let sleep = environment.sleep
        timer = Task { [weak self] in
            while let interval = self?.settings.clampedRefreshInterval {
                do { try await sleep(.seconds(interval)) } catch { return }
                await self?.refresh(force: false, reason: "timer").value
            }
        }
    }

    /// Starts a refresh, or merges into the one queued behind the refresh in
    /// flight. The task returned ends once both have run. Monitor itself is
    /// reentrant, so this is the only place refreshes are serialised.
    @discardableResult
    public func refresh(force: Bool, reason: StaticString) -> Task<Void, Never> {
        if let running {
            queued = (force || queued?.force == true, reason)
            return running
        }
        isRefreshing = true
        let task = Task { await drain(force: force, reason: reason) }
        running = task
        return task
    }

    private func drain(force: Bool, reason: StaticString) async {
        var next: (force: Bool, reason: StaticString)? = (force, reason)
        while let request = next {
            await refreshOnce(force: request.force, reason: request.reason)
            next = queued
            queued = nil
        }
        running = nil
        isRefreshing = false
    }

    private func refreshOnce(force: Bool, reason: StaticString) async {
        guard isConfigured else {
            snapshot = .empty
            pools = []
            return
        }
        snapshot = await monitor.refresh(settings.proxies, force: force, reason: reason)
        secretPresence = secrets.presence()
        let due = recompute()
        persist()
        deliver(due)
    }

    /// The panel opened: refreshes only when the snapshot is older than
    /// max(120 s, interval / 2).
    @discardableResult
    public func panelOpened() -> Task<Void, Never>? {
        let age = environment.now().timeIntervalSince(snapshot.fetchedAt)
        guard isConfigured, running == nil, age > max(120, settings.clampedRefreshInterval / 2) else { return nil }
        return refresh(force: false, reason: "panel")
    }

    /// 10 s after the Mac wakes, once the network is likely back.
    func wake() async {
        try? await environment.sleep(.seconds(10))
        await refresh(force: false, reason: "wake").value
    }

    /// The CLI changed settings.json or the Keychain item.
    func reloadAfterExternalChange() async {
        do {
            _ = adopt(try settingsStore.load())
            settingsError = nil
        } catch {
            settingsError = Self.unreadable(error)
        }
        secrets.invalidate()
        secretPresence = secrets.presence()
        await refresh(force: false, reason: "external").value
    }

    /// Pools and alerts from the snapshot and settings; returns the alerts due,
    /// none while notifications are off. Alerts are evaluated either way, so
    /// turning them on sends nothing stale.
    private func recompute() -> [QuotaAlert] {
        let now = environment.now()
        pools = Pool.summarize(snapshot, now: now, staleLimit: settings.staleLimit)
        let due = alerts.evaluate(snapshot, pools: pools, threshold: settings.lowReserveThreshold,
                                  refreshInterval: settings.clampedRefreshInterval, online: isOnline, now: now)
        return settings.notificationsEnabled ? due : []
    }

    /// The shared snapshot, history, and a widget reload when what it shows
    /// changed: at most every 15 min, at once for proxy health or the headline.
    private func persist() {
        let now = environment.now()
        let shared = SharedSnapshot(snapshot: snapshot, threshold: settings.lowReserveThreshold, pools: pools,
                                    headlineID: headline?.id, savedAt: now)
        do {
            try shared.save(to: environment.paths.snapshot)
            history = try historyStore.record(pools, at: snapshot.fetchedAt, interval: settings.clampedRefreshInterval)
            saveError = nil
        } catch {
            saveError = "Could not save: \(error.localizedDescription)"
        }
        let digest = WidgetDigest(shared)
        guard let reload = environment.reloadWidget,
              WidgetDigest.shouldReload(digest, last: widgetDigest, lastReloadAt: widgetReloadAt, now: now) else { return }
        reload()
        widgetDigest = digest
        widgetReloadAt = now
    }

    /// Delivers in order, after any earlier delivery.
    private func deliver(_ due: [QuotaAlert]) {
        guard !due.isEmpty else { return }
        let notifier = environment.notifier, previous = delivery
        delivery = Task {
            await previous?.value
            await notifier.deliver(due)
        }
    }

    // MARK: Settings

    /// Writes through `SettingsStore.update`, so what the CLI saved meanwhile
    /// is kept and a corrupt file is never overwritten, then adopts the result.
    public func update(_ change: (inout MotasSettings) throws -> Void) throws {
        if adopt(try write(change)) { refresh(force: false, reason: "settings") }
    }

    private func write(_ change: (inout MotasSettings) throws -> Void) throws -> MotasSettings {
        do {
            let next = try settingsStore.update(change)
            settingsError = nil
            return next
        } catch let error as DecodingError {
            settingsError = Self.unreadable(error)
            throw error
        }
    }

    /// Adopts settings as written or read. A changed interval restarts the
    /// timer; any change but the proxies only recomputes pools and alerts.
    /// True when the proxies changed, which calls for a refresh.
    private func adopt(_ next: MotasSettings) -> Bool {
        let old = settings
        settings = next
        if next.clampedRefreshInterval != old.clampedRefreshInterval, timer != nil { startTimer() }
        if next.proxies != old.proxies { return true }
        if next != old { deliver(recompute()) }
        return false
    }

    private static func unreadable(_ error: any Error) -> String { "settings.json is unreadable: \(error.localizedDescription)" }

    /// False while Keychain is locked: then nobody knows.
    public func hasSecret(for proxy: UUID) -> Bool { secretPresence.contains(proxy) == true }

    public var needsKeychainAccess: Bool { snapshot.proxies.contains { $0.health == .needsKeychainAccess } }

    /// The stored secret belongs to the saved server: a new kind, URL or
    /// sign-in needs a new one.
    static func needsNewSecret(_ saved: ProxyConfig, _ proxy: ProxyConfig) -> Bool {
        (saved.kind, saved.baseURL, saved.auth) != (proxy.kind, proxy.baseURL, proxy.auth)
    }

    /// Adds or replaces a proxy: settings first, then the secret (nil keeps
    /// the stored one, "" removes it). If the secret is not stored, the proxy
    /// stays saved and shows a missing credential or Allow….
    public func save(_ proxy: ProxyConfig, secret: String?) async throws {
        let next = try write { settings in
            if let index = settings.proxies.firstIndex(where: { $0.id == proxy.id }) {
                if secret == nil, Self.needsNewSecret(settings.proxies[index], proxy) { throw ProxySaveError.newSecretRequired }
                settings.proxies[index] = proxy
            } else {
                settings.proxies.append(proxy)
            }
        }
        // Adopted once the secret is written, so no refresh sends the old
        // secret to a new URL.
        defer { if adopt(next) { refresh(force: false, reason: "settings") } }
        if let secret { try await store(secret, for: proxy.id) }
    }

    /// Removes a proxy from settings, then its secret.
    public func remove(_ proxy: UUID) async throws {
        if adopt(try write { $0.proxies.removeAll { $0.id == proxy } }) { refresh(force: false, reason: "settings") }
        try await store(nil, for: proxy)
    }

    /// Writes a secret, Motas in front for a possible prompt. On failure the
    /// cache is dropped, so the proxy shows what Keychain really holds.
    private func store(_ secret: String?, for id: UUID) async throws {
        environment.activate()
        defer { secretPresence = secrets.presence() }
        do {
            try await secrets.setSecret(secret, for: id)
        } catch {
            secrets.invalidate()
            throw ProxySaveError.keychainNotUpdated(error as? SecretStoreError == .needsApproval ? "access was not allowed" : "\(error)")
        }
    }

    /// Allow…: lets macOS show its Keychain prompt, then refreshes. Approved
    /// secrets stay cached for this launch.
    public func approveKeychain() async {
        await approve()
        await refresh(force: false, reason: "keychain").value
    }

    /// The interactive Keychain read, one at a time.
    private func approve() async {
        if let approval { return await approval.value }
        let task = Task {
            // A menu bar app is not frontmost once its panel closes, and the
            // SecurityAgent prompt then opens behind other windows.
            environment.activate()
            do {
                try await secrets.approve()
                secretError = nil
            } catch SecretStoreError.needsApproval {
                // Declined: the banner stays.
            } catch {
                secretError = "Keychain: \(error)"
            }
            secretPresence = secrets.presence()
            legacyKeychainMigrated = preferences.legacyKeychainMigrated
            approval = nil
        }
        approval = task
        await task.value
    }

    /// Sends a sample alert so the user can check Notification Center settings.
    public func sendTestNotification() async -> NotificationDelivery {
        await environment.notifier.deliver([QuotaAlert(kind: .poolLow, key: "test", title: "Motas test notification",
                                                       body: "This is what a low-quota or proxy-down alert looks like.")])
    }

    /// Settings' Test: lists the proxy once with `secret`, else with the
    /// stored one, unless kind, URL or sign-in changed (it belongs to the
    /// saved server). A user action, so it may ask for Keychain approval.
    public func test(_ proxy: ProxyConfig, secret: String?) async -> Result<[AccountDescriptor], ProxyAccessError> {
        var resolved = secret
        if resolved == nil, let saved = settings.proxies.first(where: { $0.id == proxy.id }), !Self.needsNewSecret(saved, proxy) {
            resolved = await storedSecret(for: proxy.id)
        }
        return await monitor.test(proxy, secret: resolved)
    }

    /// Off the main thread: a background read may wait up to 0.2 s.
    private func storedSecret(for id: UUID) async -> String? {
        let secrets = self.secrets
        func read() async throws -> String? { try await Task.detached { try secrets.secret(for: id) }.value }
        do {
            return try await read()
        } catch SecretStoreError.needsApproval {
            await approve()
            return try? await read()
        } catch {
            return nil
        }
    }

    // MARK: Launch at login

    /// Through `SMAppService.mainApp`, which needs the installed Motas.app.
    public var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    public func setLaunchAtLogin(_ on: Bool) throws {
        objectWillChange.send()
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

extension AppModel {
    /// The live `observe`: the network path sets `isOnline`, a wake refreshes
    /// 10 s later, and the CLI's change notice reloads settings and secrets.
    static func observeSystem(_ model: AppModel) -> [AnyObject] {
        let network = NWPathMonitor()
        network.pathUpdateHandler = { [weak model] path in
            let online = path.status == .satisfied
            Task { @MainActor [model] in model?.isOnline = online }
        }
        network.start(queue: .main)
        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                     queue: .main) { [weak model] _ in
            Task { @MainActor [model] in await model?.wake() }
        }
        let changes = NotificationTarget { [weak model] in
            Task { @MainActor [model] in await model?.reloadAfterExternalChange() }
        }
        // Delivered even while Motas is in the background, which is always.
        DistributedNotificationCenter.default().addObserver(changes, selector: #selector(NotificationTarget.receive(_:)),
                                                            name: MotasCLI.settingsChanged, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        return [network, wake as AnyObject, changes]
    }
}

/// `DistributedNotificationCenter` takes a suspension behavior only with a
/// selector, so the CLI's change notice needs an Objective-C target.
private final class NotificationTarget: NSObject {
    private let action: @Sendable () -> Void

    init(_ action: @escaping @Sendable () -> Void) { self.action = action }

    @objc func receive(_ notification: Notification) { action() }
}
