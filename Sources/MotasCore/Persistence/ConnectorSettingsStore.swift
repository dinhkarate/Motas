import Foundation

public enum ConnectorSettingsStoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidDocument(String)
}

/// Persists non-secret connector settings.
///
/// A store never touches secret values; it owns only a settings document.
public protocol ConnectorSettingsStore: Sendable {
    func load() throws -> MotasSettings?
    func save(_ settings: MotasSettings) throws
}

/// Atomic JSON-backed settings store.
///
/// State is limited to an immutable file URL for Swift 6 safety. A missing file
/// returns `nil`; a malformed document throws and is never silently overwritten
/// at startup.
public struct JSONConnectorSettingsStore: ConnectorSettingsStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> MotasSettings? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)

        do {
            let envelope = try JSONDecoder().decode(SchemaEnvelope.self, from: data)
            guard envelope.schemaVersion <= MotasSettings.currentSchemaVersion else {
                throw ConnectorSettingsStoreError.unsupportedSchemaVersion(envelope.schemaVersion)
            }
            return try JSONDecoder().decode(MotasSettings.self, from: data)
        } catch let error as ConnectorSettingsStoreError {
            throw error
        } catch {
            throw ConnectorSettingsStoreError.invalidDocument(error.localizedDescription)
        }
    }

    public func save(_ settings: MotasSettings) throws {
        guard settings.schemaVersion <= MotasSettings.currentSchemaVersion else {
            throw ConnectorSettingsStoreError.unsupportedSchemaVersion(settings.schemaVersion)
        }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }
}

private struct SchemaEnvelope: Decodable {
    let schemaVersion: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schemaVersion"
    }
}
