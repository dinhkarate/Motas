import Foundation
import Testing
@testable import MotasCore

@Test("Snapshot round-trips through an atomic JSON file")
func snapshotRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = SnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))
    let snapshot = MockData.fallbackSnapshot(at: Date(timeIntervalSince1970: 1_750_000_000))

    try store.save(snapshot)
    let loaded = try store.load()

    #expect(loaded == snapshot)
}

@Test("Missing snapshot returns nil")
func missingSnapshotReturnsNil() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let store = SnapshotStore(fileURL: file)

    #expect(try store.load() == nil)
}

@Test("Encoded snapshot does not contain credential-like fields")
func snapshotDoesNotContainSecrets() throws {
    let snapshot = MockData.readySnapshot(at: Date(timeIntervalSince1970: 1_750_000_000))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = String(decoding: try encoder.encode(snapshot), as: UTF8.self).lowercased()

    #expect(!encoded.contains("apikey"))
    #expect(!encoded.contains("api_key"))
    #expect(!encoded.contains("authorization"))
    #expect(!encoded.contains("cookie"))
    #expect(!encoded.contains("token"))
}
