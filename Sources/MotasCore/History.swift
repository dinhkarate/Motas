import Foundation

/// One pool reading. Only normalized numbers — no labels, ids or secrets.
public struct PoolSample: Codable, Sendable, Hashable {
    public var at: Date
    public var provider: Provider
    public var reserve: Double

    public init(at: Date, provider: Provider, reserve: Double) {
        self.at = at
        self.provider = provider
        self.reserve = reserve
    }
}

/// Bounded pool history (default 7 days) in a single JSON file.
public struct HistoryStore: Sendable {
    public let url: URL
    public let retention: TimeInterval
    /// Minimum spacing between samples of the same provider.
    public let spacing: TimeInterval

    public init(url: URL, retention: TimeInterval = 7 * 86_400, spacing: TimeInterval = 240) {
        self.url = url
        self.retention = retention
        self.spacing = spacing
    }

    public func load() -> [PoolSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([PoolSample].self, from: data)) ?? []
    }

    /// Appends measured pools from `snapshot`, prunes, persists, returns the result.
    @discardableResult
    public func record(_ pools: [PoolSummary], at now: Date) throws -> [PoolSample] {
        var samples = load().filter { now.timeIntervalSince($0.at) <= retention }
        for pool in pools {
            guard let reserve = pool.reserve else { continue }
            if let last = samples.last(where: { $0.provider == pool.provider }), now.timeIntervalSince(last.at) < spacing { continue }
            samples.append(PoolSample(at: now, provider: pool.provider, reserve: reserve))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(samples).write(to: url, options: .atomic)
        return samples
    }
}
