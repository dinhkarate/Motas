import Foundation

public struct MotasSettings: Codable, Sendable, Hashable {
    public var proxies: [ProxyConfig]
    /// Seconds between automatic refreshes; clamped to 60…3600.
    public var refreshInterval: TimeInterval
    /// Pool reserve below which the menu bar turns amber and a notification fires.
    public var lowReserveThreshold: Double
    public var notificationsEnabled: Bool
    /// Per-pool choices by `PoolKey.id`; a pool without an entry uses the defaults.
    public var pools: [String: PoolOptions]

    public init(proxies: [ProxyConfig] = [], refreshInterval: TimeInterval = 300, lowReserveThreshold: Double = 0.2, notificationsEnabled: Bool = true,
                pools: [String: PoolOptions] = [:]) {
        self.proxies = proxies
        self.refreshInterval = refreshInterval
        self.lowReserveThreshold = lowReserveThreshold
        self.notificationsEnabled = notificationsEnabled
        self.pools = pools
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MotasSettings()
        proxies = try c.decodeIfPresent([ProxyConfig].self, forKey: .proxies) ?? d.proxies
        refreshInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? d.refreshInterval
        lowReserveThreshold = try c.decodeIfPresent(Double.self, forKey: .lowReserveThreshold) ?? d.lowReserveThreshold
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        pools = try c.decodeIfPresent([String: PoolOptions].self, forKey: .pools) ?? d.pools
    }

    public var clampedRefreshInterval: TimeInterval { min(max(refreshInterval, 60), 3600) }

    /// How old an account's figures may be before pools treat them as unknown.
    public var staleLimit: TimeInterval { max(30 * 60, 3 * clampedRefreshInterval) }

    public func options(for poolID: String) -> PoolOptions { pools[poolID] ?? PoolOptions() }

    /// The pool's own warning level, else the global one.
    public func threshold(for poolID: String) -> Double { pools[poolID]?.lowReserveThreshold ?? lowReserveThreshold }

    /// Changes one pool's options; an entry back at the defaults is dropped.
    public mutating func setOptions(for poolID: String, _ change: (inout PoolOptions) -> Void) {
        var options = options(for: poolID)
        change(&options)
        pools[poolID] = options == PoolOptions() ? nil : options
    }
}

/// What the user chose for one pool (Codex, Gemini, Claude & GPT …).
public struct PoolOptions: Codable, Sendable, Hashable {
    /// Warn below this reserve; nil = `MotasSettings.lowReserveThreshold`.
    public var lowReserveThreshold: Double?
    /// The window period the reserve is read from ("5h", "weekly" …); nil = the
    /// lowest window. Members without that window keep the lowest.
    public var basis: String?
    /// Low and exhausted notifications for this pool.
    public var notify: Bool
    /// Left out of the cards, the menu bar, the desktop and alerts.
    public var hidden: Bool

    public init(lowReserveThreshold: Double? = nil, basis: String? = nil, notify: Bool = true, hidden: Bool = false) {
        self.lowReserveThreshold = lowReserveThreshold
        self.basis = basis
        self.notify = notify
        self.hidden = hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowReserveThreshold = try c.decodeIfPresent(Double.self, forKey: .lowReserveThreshold)
        basis = try c.decodeIfPresent(String.self, forKey: .basis)
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

/// JSON file persistence. A corrupt file is reported, never silently replaced.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Motas", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public func load() throws -> MotasSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return MotasSettings() }
        return try JSONDecoder().decode(MotasSettings.self, from: Data(contentsOf: url))
    }

    public func save(_ settings: MotasSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }

    /// Re-reads the file, applies `change` and writes atomically, so what
    /// another writer (the CLI) saved meanwhile is kept. A corrupt file throws
    /// and is never overwritten.
    @discardableResult
    public func update(_ change: (inout MotasSettings) throws -> Void) throws -> MotasSettings {
        var settings = try load()
        try change(&settings)
        try save(settings)
        return settings
    }
}

/// UI-only preferences in UserDefaults. None of them trigger a refresh, and
/// none are stored in settings.json. Tests inject a suite.
public struct UIPreferences: @unchecked Sendable {   // UserDefaults is thread-safe
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The pinned menu-bar pool id; nil = automatic.
    public var menuBarPool: String? {
        get { defaults.string(forKey: "menuBarPool") }
        nonmutating set { defaults.set(newValue, forKey: "menuBarPool") }
    }

    public var desktopWidgetEnabled: Bool {
        get { defaults.bool(forKey: "desktopWidget.enabled") }
        nonmutating set { defaults.set(newValue, forKey: "desktopWidget.enabled") }
    }

    public var desktopWidgetLocked: Bool {
        get { defaults.bool(forKey: "desktopWidget.locked") }
        nonmutating set { defaults.set(newValue, forKey: "desktopWidget.locked") }
    }

    /// Card order by pool id; nil = the fixed order.
    public var desktopWidgetCards: [String]? {
        get { defaults.stringArray(forKey: "desktopWidget.cards") }
        nonmutating set { defaults.set(newValue, forKey: "desktopWidget.cards") }
    }

    public var onboardingDone: Bool {
        get { defaults.bool(forKey: "onboardingDone") }
        nonmutating set { defaults.set(newValue, forKey: "onboardingDone") }
    }

    public var legacyKeychainMigrated: Bool {
        get { defaults.bool(forKey: "legacyKeychainMigrated") }
        nonmutating set { defaults.set(newValue, forKey: "legacyKeychainMigrated") }
    }
}
