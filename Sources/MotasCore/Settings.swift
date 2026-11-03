import Foundation

public struct MotasSettings: Codable, Sendable, Hashable {
    public var proxies: [ProxyConfig]
    /// Seconds between automatic refreshes; clamped to 60…3600.
    public var refreshInterval: TimeInterval
    /// Pool reserve below which the menu bar turns amber and a notification fires.
    public var lowReserveThreshold: Double
    public var notificationsEnabled: Bool

    public init(proxies: [ProxyConfig] = [], refreshInterval: TimeInterval = 300, lowReserveThreshold: Double = 0.2, notificationsEnabled: Bool = true) {
        self.proxies = proxies
        self.refreshInterval = refreshInterval
        self.lowReserveThreshold = lowReserveThreshold
        self.notificationsEnabled = notificationsEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MotasSettings()
        proxies = try c.decodeIfPresent([ProxyConfig].self, forKey: .proxies) ?? d.proxies
        refreshInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? d.refreshInterval
        lowReserveThreshold = try c.decodeIfPresent(Double.self, forKey: .lowReserveThreshold) ?? d.lowReserveThreshold
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
    }

    public var clampedRefreshInterval: TimeInterval { min(max(refreshInterval, 60), 3600) }

    /// How old an account's figures may be before pools treat them as unknown.
    public var staleLimit: TimeInterval { max(30 * 60, 3 * clampedRefreshInterval) }
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
