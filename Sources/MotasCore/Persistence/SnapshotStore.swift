import Foundation

public enum SnapshotStoreError: Error, Equatable {
    case appGroupUnavailable(String)
}

public struct SnapshotStore: Sendable {
    public static let defaultFilename = "motas-status-snapshot.json"

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(
        appGroupIdentifier: String,
        filename: String = SnapshotStore.defaultFilename,
        fileManager: FileManager = .default
    ) throws {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw SnapshotStoreError.appGroupUnavailable(appGroupIdentifier)
        }
        self.fileURL = container.appendingPathComponent(filename, isDirectory: false)
    }

    public func save(_ snapshot: StatusSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func load() throws -> StatusSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StatusSnapshot.self, from: Data(contentsOf: fileURL))
    }
}
