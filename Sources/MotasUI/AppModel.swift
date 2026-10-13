import Foundation
import MotasCore
import SwiftUI

public protocol Notifier: Sendable {
    func deliver(_ alerts: [QuotaAlert]) async
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

    let settingsStore: SettingsStore
    let secrets: any SecretStore
    let historyStore: HistoryStore
    let snapshotURL: URL
    let monitor: Monitor
    let notifier: any Notifier
    private var previous: Snapshot?
    private var loop: Task<Void, Never>?
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
                autoRefresh: Bool = true) {
        self.autoRefresh = autoRefresh
        settingsStore = SettingsStore(url: paths.settings)
        historyStore = HistoryStore(url: paths.history)
        snapshotURL = paths.snapshot
        self.secrets = secrets
        monitor = Monitor(http: http)
        self.notifier = notifier
        do {
            settings = try settingsStore.load()
        } catch {
            settings = MotasSettings()
            appError = "settings.json could not be read and was left untouched: \(error.localizedDescription)"
        }
        // Last real snapshot, shown with its age until the first refresh lands.
        snapshot = SharedSnapshot.load(from: paths.snapshot).map { $0.snapshot } ?? .empty
        if !settings.proxies.isEmpty {
            snapshot.proxies = snapshot.proxies.filter { p in settings.proxies.contains { $0.id == p.id && $0.isEnabled } }
        } else {
            snapshot = .empty
        }
        pools = Pool.summarize(snapshot)
        history = historyStore.load()
        // Started here, not from a view: a MenuBarExtra label's .task never runs.
        if autoRefresh { start() }
    }

    public var isConfigured: Bool { settings.proxies.contains(where: \.isEnabled) }
    public var headline: PoolSummary? { Pool.headline(pools) }

    public func start() {
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
        let current = await monitor.refresh(settings.proxies, secrets: secrets)
        snapshot = current
        pools = Pool.summarize(current)
        if settings.notificationsEnabled {
            let alerts = AlertRules.alerts(previous: previous, current: current, threshold: settings.lowReserveThreshold)
            if !alerts.isEmpty { await notifier.deliver(alerts) }
        }
        previous = current
        do {
            history = try historyStore.record(pools, at: current.fetchedAt)
            try SharedSnapshot(snapshot: current, threshold: settings.lowReserveThreshold).save(to: snapshotURL)
            appError = nil
        } catch {
            appError = "Could not save history: \(error.localizedDescription)"
        }
    }

    // MARK: Settings

    public func hasSecret(for proxy: UUID) -> Bool { secrets.hasSecret(for: proxy) }

    public var needsKeychainAccess: Bool { snapshot.proxies.contains { $0.health == .needsKeychainAccess } }

    /// User-initiated: lets macOS show its Keychain prompt (off the main
    /// thread), then refreshes. Approved secrets stay cached for this launch.
    public func approveKeychainAccess() async {
        let ids = settings.proxies.map(\.id)
        let secrets = self.secrets
        await Task.detached { for id in ids { _ = try? secrets.secret(for: id, interactive: true) } }.value
        await refresh()
    }

    /// Saves (adds or replaces) a proxy. `secret == nil` keeps the stored one.
    public func save(_ proxy: ProxyConfig, secret: String?) throws {
        if let secret { try secrets.setSecret(secret, for: proxy.id) }
        var next = settings
        if let index = next.proxies.firstIndex(where: { $0.id == proxy.id }) {
            next.proxies[index] = proxy
        } else {
            next.proxies.append(proxy)
        }
        try apply(next)
    }

    public func remove(_ proxy: UUID) throws {
        var next = settings
        next.proxies.removeAll { $0.id == proxy }
        try apply(next)
        try secrets.setSecret(nil, for: proxy)
    }

    public func update(_ change: (inout MotasSettings) -> Void) throws {
        var next = settings
        change(&next)
        try apply(next)
    }

    private func apply(_ next: MotasSettings) throws {
        try settingsStore.save(next)
        let intervalChanged = next.clampedRefreshInterval != settings.clampedRefreshInterval
        settings = next
        appError = nil
        guard autoRefresh else { return }
        if intervalChanged || loop == nil { start() } else { Task { await refresh() } }
    }

    public func test(_ proxy: ProxyConfig, secret: String?) async -> ProxySnapshot {
        var resolved = secret
        if resolved == nil {
            let secrets = self.secrets, id = proxy.id
            resolved = await Task.detached { try? secrets.secret(for: id, interactive: true) }.value
        }
        return await monitor.test(proxy, secret: resolved)
    }
}
