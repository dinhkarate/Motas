import Foundation

/// The latest snapshot and what was derived from it, written by the app after
/// every refresh. The widget reads the pools and the headline from here and
/// never recomputes them.
public struct SharedSnapshot: Codable, Sendable {
    public var snapshot: Snapshot
    public var threshold: Double
    /// In the fixed order.
    public var pools: [PoolSummary]
    public var headlineID: String?
    /// Proxies whose accounts were carried from an earlier refresh.
    public var staleProxies: Int
    /// Proxies with a problem of their own (`ProxySnapshot.isUnhealthy`).
    public var unhealthyProxies: Int
    public var savedAt: Date

    public init(snapshot: Snapshot, threshold: Double, pools: [PoolSummary], headlineID: String?, savedAt: Date) {
        self.snapshot = snapshot
        self.threshold = threshold
        self.pools = pools
        self.headlineID = headlineID
        staleProxies = snapshot.proxies.filter { !$0.health.isOK }.count
        unhealthyProxies = snapshot.proxies.filter(\.isUnhealthy).count
        self.savedAt = savedAt
    }

    /// Files written before pools were saved (0.2) still decode, without pools.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try c.decode(Snapshot.self, forKey: .snapshot)
        threshold = try c.decode(Double.self, forKey: .threshold)
        pools = try c.decodeIfPresent([PoolSummary].self, forKey: .pools) ?? []
        headlineID = try c.decodeIfPresent(String.self, forKey: .headlineID)
        staleProxies = try c.decodeIfPresent(Int.self, forKey: .staleProxies) ?? 0
        unhealthyProxies = try c.decodeIfPresent(Int.self, forKey: .unhealthyProxies) ?? 0
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? snapshot.fetchedAt
    }

    public static let appGroup = "group.dev.motas"

    /// App Group container when available (signed app + widget), else
    /// Application Support (unbundled / development runs).
    public static var url: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Motas", isDirectory: true)
        return base.appendingPathComponent("snapshot.json")
    }

    public static func load(from url: URL = SharedSnapshot.url) -> SharedSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedSnapshot.self, from: data)
    }

    public func save(to url: URL = SharedSnapshot.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// What the WidgetKit widget shows, reduced to what should reload it.
public struct WidgetDigest: Sendable, Hashable {
    public var headlineID: String?
    public var headlinePercent: Int?
    /// Pool id → whole percent, for the pools with a reserve.
    public var pools: [String: Int]
    /// Pool id → usable accounts.
    public var usable: [String: Int]
    public var unhealthyProxies: Int

    public init(_ shared: SharedSnapshot) {
        func percent(_ fraction: Double?) -> Int? { fraction.map { Int(($0 * 100).rounded()) } }
        headlineID = shared.headlineID
        headlinePercent = percent(shared.pools.first { $0.id == shared.headlineID }?.reserve)
        pools = shared.pools.reduce(into: [:]) { $0[$1.id] = percent($1.reserve) }
        usable = shared.pools.reduce(into: [:]) { $0[$1.id] = $1.usable }
        unhealthyProxies = shared.unhealthyProxies
    }

    /// Reload when `digest` differs from the one the widget was last reloaded
    /// with (`last`) and 15 minutes have passed since that reload; a change of
    /// proxy health or of the headline does not wait.
    public static func shouldReload(_ digest: WidgetDigest, last: WidgetDigest?, lastReloadAt: Date?, now: Date) -> Bool {
        guard digest != last else { return false }
        guard let last, let lastReloadAt else { return true }
        if digest.headlineID != last.headlineID || digest.unhealthyProxies != last.unhealthyProxies { return true }
        return now.timeIntervalSince(lastReloadAt) >= 15 * 60
    }
}
