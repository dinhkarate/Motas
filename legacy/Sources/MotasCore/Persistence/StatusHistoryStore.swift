import Foundation

public enum StatusHistoryStoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidDocument(String)
}

public protocol StatusHistoryStore: Sendable {
    func load() throws -> StatusHistory
    func save(_ history: StatusHistory) throws
    func delete() throws
}

public struct JSONStatusHistoryStore: StatusHistoryStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> StatusHistory {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return StatusHistory()
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let envelope = try JSONDecoder().decode(SchemaEnvelope.self, from: data)
            guard envelope.schemaVersion <= StatusHistory.currentSchemaVersion else {
                throw StatusHistoryStoreError.unsupportedSchemaVersion(envelope.schemaVersion)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(StatusHistory.self, from: data)
        } catch let error as StatusHistoryStoreError {
            throw error
        } catch {
            throw StatusHistoryStoreError.invalidDocument(error.localizedDescription)
        }
    }

    public func save(_ history: StatusHistory) throws {
        guard history.schemaVersion <= StatusHistory.currentSchemaVersion else {
            throw StatusHistoryStoreError.unsupportedSchemaVersion(history.schemaVersion)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(history).write(to: fileURL, options: [.atomic])
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public extension StatusHistoryStore {
    func delete() throws {}
}

private struct SchemaEnvelope: Decodable {
    let schemaVersion: Int
}
