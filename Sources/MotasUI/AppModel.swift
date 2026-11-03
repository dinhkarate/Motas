import AppKit
import Foundation
import MotasCore
import SwiftUI

public protocol Notifier: Sendable {
    @discardableResult
    func deliver(_ alerts: [QuotaAlert]) async -> NotificationDelivery
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
    /// A problem with Motas itself (settings file, Keychain, disk) — not a proxy problem.
    @Published public private(set) var appError: String?
    /// Which proxies have a secret, from the store's cache; never read from Keychain itself.
    @Published public private(set) var secretPresence: SecretPresence = .locked

    let settingsStore: SettingsStore
    let secrets: any SecretStore
    let historyStore: HistoryStore
    let snapshotURL: URL
    let monitor: Monitor
    let notifier: any Notifier
    let preferences: UIPreferences
    private var alerts = AlertEngine()
    private var loop: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var pendingRefresh = false
    /// False in tests: settings changes do not start the refresh loop.
    let autoRefresh: Bool

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

    public init(paths: Paths = .standard, secrets: any SecretStore = KeychainSecretStore(),
                http: any HTTPClient = URLSessionHTTPClient(), notifier: any Notifier = SystemNotifier(),
                preferences: UIPreferences = UIPreferences(), autoRefresh: Bool = true) {
        self.autoRefresh = autoRefresh
        self.preferences = preferences
        settingsStore = SettingsStore(url: paths.settings)
        historyStore = HistoryStore(url: paths.history)
        snapshotURL = paths.snapshot
        self.secrets = secrets
        self.notifier = notifier
        let settings: MotasSettings
        do {
            settings = try settingsStore.load()
        } catch {
            settings = MotasSettings()
            appError = "settings.json is unreadable: \(error.localizedDescription)"
        }
        // Last real snapshot, shown with its age until the first refresh lands.
        var snapshot = SharedSnapshot.load(from: paths.snapshot).map { $0.snapshot } ?? .empty
        if !settings.proxies.isEmpty {
            snapshot.proxies = snapshot.proxies.filter { p in settings.proxies.contains { $0.id == p.id && $0.isEnabled } }
        } else {
            snapshot = .empty
        }
        self.settings = settings
        self.snapshot = snapshot
        monitor = Monitor(http: http, secrets: secrets, seed: snapshot)
        pools = Pool.summarize(snapshot, now: .now, staleLimit: settings.staleLimit)
        history = historyStore.load()
        secretPresence = secrets.presence()
        // Started here, not from a view: a MenuBarExtra label's .task never runs.
        if autoRefresh { start() }
    }

    public var isConfigured: Bool { settings.proxies.contains(where: \.isEnabled) }
    public var headline: PoolSummary? { Pool.headline(pools, pinned: preferences.menuBarPool) }

    public func start() {
        // A background menu bar app gets App Nap, which stretches the refresh
        // timer well past its interval. Opt out (idle system sleep still allowed).
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Monitoring proxy quota")
        }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.settings.clampedRefreshInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Coalesces overlapping requests: at most one in flight plus one queued.
    public func refresh() async {
        if isRefreshing { pendingRefresh = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            pendingRefresh = false
            await refreshOnce()
        } while pendingRefresh
    }

    private func refreshOnce() async {
        guard isConfigured else {
            snapshot = .empty
            pools = []
            return
        }
        let current = await monitor.refresh(settings.proxies, force: false, reason: "refresh")
        let now = Date.now
        snapshot = current
        secretPresence = secrets.presence()
        pools = Pool.summarize(current, now: now, staleLimit: settings.staleLimit)
        // Evaluated even with notifications off, so turning them on sends nothing stale.
        let due = alerts.evaluate(current, pools: pools, threshold: settings.lowReserveThreshold,
                                  refreshInterval: settings.clampedRefreshInterval, online: true, now: now)
        if settings.notificationsEnabled, !due.isEmpty { await notifier.deliver(due) }
        do {
            history = try historyStore.record(pools, at: current.fetchedAt, interval: settings.clampedRefreshInterval)
            try SharedSnapshot(snapshot: current, threshold: settings.lowReserveThreshold, pools: pools, headlineID: headline?.id,
                               savedAt: now).save(to: snapshotURL)
            appError = nil
        } catch {
            appError = "Could not save history: \(error.localizedDescription)"
        }
    }

    // MARK: Settings

    /// False while Keychain is locked: then nobody knows.
    public func hasSecret(for proxy: UUID) -> Bool { secretPresence.contains(proxy) == true }

    public var needsKeychainAccess: Bool { snapshot.proxies.contains { $0.health == .needsKeychainAccess } }

    /// User-initiated: lets macOS show its Keychain prompt (on the store's
    /// queue), then refreshes. Approved secrets stay cached for this launch.
    public func approveKeychainAccess() async {
        // A menu bar app is not frontmost once its panel closes, and the
        // SecurityAgent prompt then opens behind other windows. Activate first.
        NSApplication.shared.activate(ignoringOtherApps: true)
        var failure: String?
        do {
            try await secrets.approve()
        } catch SecretStoreError.needsApproval {
            // Declined: the banner stays.
        } catch {
            failure = "Keychain: \(error)"
        }
        secretPresence = secrets.presence()
        await refresh()
        if let failure { appError = failure }
    }

    /// Saves (adds or replaces) a proxy. `secret == nil` keeps the stored one.
    public func save(_ proxy: ProxyConfig, secret: String?) async throws {
        if let secret {
            try await secrets.setSecret(secret, for: proxy.id)
            secretPresence = secrets.presence()
        }
        try update { settings in
            if let index = settings.proxies.firstIndex(where: { $0.id == proxy.id }) {
                settings.proxies[index] = proxy
            } else {
                settings.proxies.append(proxy)
            }
        }
    }

    public func remove(_ proxy: UUID) async throws {
        try update { $0.proxies.removeAll { $0.id == proxy } }
        try await secrets.setSecret(nil, for: proxy)
        secretPresence = secrets.presence()
    }

    /// Writes through `SettingsStore.update`, so what the CLI saved meanwhile
    /// is kept and a corrupt file is never overwritten, and adopts the result.
    public func update(_ change: (inout MotasSettings) -> Void) throws {
        let next = try settingsStore.update(change)
        let intervalChanged = next.clampedRefreshInterval != settings.clampedRefreshInterval
        settings = next
        appError = nil
        guard autoRefresh else { return }
        if intervalChanged || loop == nil { start() } else { Task { await refresh() } }
    }

    /// Sends a sample alert so the user can check Notification Center settings.
    public func sendTestNotification() async -> NotificationDelivery {
        await notifier.deliver([QuotaAlert(kind: .poolLow, key: "test", title: "Motas test notification",
                                           body: "This is what a low-quota or proxy-down alert looks like.")])
    }

    public func test(_ proxy: ProxyConfig, secret: String?) async -> Result<[AccountDescriptor], ProxyAccessError> {
        var resolved = secret
        if resolved == nil {
            // The stored secret, off the main thread. Test is a user action, so it may ask for approval.
            let secrets = self.secrets, id = proxy.id
            resolved = await Task.detached {
                do {
                    return try secrets.secret(for: id)
                } catch SecretStoreError.needsApproval {
                    try? await secrets.approve()
                    return try? secrets.secret(for: id)
                } catch {
                    return nil
                }
            }.value
            secretPresence = secrets.presence()
        }
        return await monitor.test(proxy, secret: resolved)
    }
}
