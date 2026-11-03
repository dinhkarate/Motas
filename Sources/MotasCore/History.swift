import Foundation

/// One pool reading: its id and reserve, never a label or a secret.
public struct PoolSample: Codable, Sendable, Hashable {
    public var at: Date
    /// `PoolSummary.id`.
    public var pool: String
    public var reserve: Double

    public init(at: Date, pool: String, reserve: Double) {
        self.at = at
        self.pool = pool
        self.reserve = reserve
    }
}

/// Bounded pool history (default 7 days) in a single JSON file.
public struct HistoryStore: Sendable {
    public let url: URL
    public let retention: TimeInterval

    public init(url: URL, retention: TimeInterval = 7 * 86_400) {
        self.url = url
        self.retention = retention
    }

    /// Decoded element by element: unreadable samples are skipped, and so are
    /// 0.2's provider-keyed ones, whose means are not comparable with tiered pools.
    public func load() -> [PoolSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return ((try? decoder.decode([Lenient].self, from: data)) ?? []).compactMap(\.sample)
    }

    /// Appends the measured pools, at most one sample per pool per `interval`
    /// (the refresh interval), prunes, persists and returns the result.
    @discardableResult
    public func record(_ pools: [PoolSummary], at now: Date, interval: TimeInterval) throws -> [PoolSample] {
        var samples = load().filter { now.timeIntervalSince($0.at) <= retention }
        for pool in pools {
            guard let reserve = pool.reserve else { continue }
            if let last = samples.last(where: { $0.pool == pool.id }), now.timeIntervalSince(last.at) < interval { continue }
            samples.append(PoolSample(at: now, pool: pool.id, reserve: reserve))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(samples).write(to: url, options: .atomic)
        return samples
    }

    /// One array element that may not be a sample.
    private struct Lenient: Decodable {
        var sample: PoolSample?

        init(from decoder: any Decoder) throws { sample = try? PoolSample(from: decoder) }
    }
}
