import Foundation

/// The latest snapshot, written by the app and read by the widget.
public struct SharedSnapshot: Codable, Sendable {
    public var snapshot: Snapshot
    public var threshold: Double

    public init(snapshot: Snapshot, threshold: Double) {
        self.snapshot = snapshot
        self.threshold = threshold
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
