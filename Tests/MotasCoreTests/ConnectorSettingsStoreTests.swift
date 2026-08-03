import Foundation
import Testing
@testable import MotasCore

private func temporaryStore() throws -> JSONConnectorSettingsStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return JSONConnectorSettingsStore(
        fileURL: directory.appendingPathComponent("settings.json")
    )
}

@Test("Missing settings file returns nil")
func missingSettingsFileReturnsNil() throws {
    let store = JSONConnectorSettingsStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
    )
    #expect(try store.load() == nil)
}

@Test("Settings round-trip through atomic JSON")
func settingsRoundTrip() throws {
    let store = try temporaryStore()
    let settings = MotasSettings(
        automaticRefreshEnabled: false,
        claudeCode: ClaudeCodeSettings(isEnabled: true),
        nineRouter: NineRouterSettings(
            isEnabled: true,
            baseURL: URL(string: "http://localhost:20128")!
        ),
        cliProxyAPI: CLIProxyAPISettings(
            isEnabled: true,
            baseURL: URL(string: "http://localhost:8317")!
        )
    )

    try store.save(settings)
    let loaded = try store.load()

    #expect(loaded == settings)
}

@Test("Defaults are decodable and reflection-free of secrets")
func defaultsMatchExpectedValues() {
    let defaults = MotasSettings.default()
    #expect(defaults.automaticRefreshEnabled == true)
    #expect(defaults.nineRouter.isEnabled == false)
    #expect(defaults.nineRouter.baseURL.absoluteString == "http://localhost:20128")
    #expect(defaults.cliProxyAPI.isEnabled == false)
    #expect(defaults.cliProxyAPI.baseURL.absoluteString == "http://localhost:8317")
}

@Test("Encoded settings do not contain secret fields")
func settingsDoNotContainSecrets() throws {
    let settings = MotasSettings()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = String(decoding: try encoder.encode(settings), as: UTF8.self).lowercased()

    #expect(!encoded.contains("token"))
    #expect(!encoded.contains("apikey"))
    #expect(!encoded.contains("key"))
    #expect(!encoded.contains("secret"))
}

@Test("Malformed settings throws and is not overwritten")
func malformedSettingsThrows() throws {
    let store = try temporaryStore()
    try store.save(MotasSettings())

    let encoder = JSONEncoder()
    let corrupted = try encoder.encode(MotasSettings())
    let text = String(decoding: corrupted, as: UTF8.self) + "not-json"
    try Data(text.utf8).write(to: store.fileURL)

    #expect(throws: ConnectorSettingsStoreError.self) {
        _ = try store.load()
    }
}

@Test("Future schema version throws")
func futureSchemaThrows() throws {
    let store = try temporaryStore()
    let data = Data(#"{"schemaVersion": 99}"#.utf8)
    try data.write(to: store.fileURL)

    #expect(throws: ConnectorSettingsStoreError.unsupportedSchemaVersion(99)) {
        _ = try store.load()
    }
}

@Test("Valid local endpoints are accepted")
func validEndpointsAccepted() throws {
    let settings = MotasSettings(
        nineRouter: NineRouterSettings(baseURL: URL(string: "https://router.example.com:8443")!),
        cliProxyAPI: CLIProxyAPISettings(
            baseURL: URL(string: "http://localhost:8317/v1")!
        )
    )
    #expect(try settings.validated().nineRouter.baseURL.absoluteString == "https://router.example.com:8443")
    #expect(try settings.validated().cliProxyAPI.baseURL.absoluteString == "http://localhost:8317")
}

@Test("Endpoints with embedded credentials are rejected")
func endpointsWithCredentialsRejected() throws {
    let withUser = MotasSettings(
        nineRouter: NineRouterSettings(
            baseURL: URL(string: "http://user:secret@localhost:20128")!
        )
    )
    #expect(throws: ConnectorSettingsValidationError.embeddedCredentials("9Router endpoint")) {
        _ = try withUser.validated()
    }

    let withQuery = MotasSettings(
        cliProxyAPI: CLIProxyAPISettings(
            baseURL: URL(string: "http://localhost:8317?api_key=secret")!
        )
    )
    #expect(throws: ConnectorSettingsValidationError.unsupportedQueryOrFragment("CLIProxyAPI endpoint")) {
        _ = try withQuery.validated()
    }
}

@Test("Endpoints with unsupported scheme, missing host or fragment are rejected")
func endpointsInvalidRejected() throws {
    let scheme = MotasSettings(
        nineRouter: NineRouterSettings(baseURL: URL(string: "ftp://localhost:20128")!)
    )
    #expect(throws: ConnectorSettingsValidationError.invalidScheme("9Router endpoint")) {
        _ = try scheme.validated()
    }

    let missingHost = MotasSettings(
        cliProxyAPI: CLIProxyAPISettings(baseURL: URL(string: "http://")!)
    )
    #expect(throws: ConnectorSettingsValidationError.missingHost("CLIProxyAPI endpoint")) {
        _ = try missingHost.validated()
    }

    let fragment = MotasSettings(
        nineRouter: NineRouterSettings(baseURL: URL(string: "http://localhost:20128#frag")!)
    )
    #expect(throws: ConnectorSettingsValidationError.unsupportedQueryOrFragment("9Router endpoint")) {
        _ = try fragment.validated()
    }
}

@Test("Nonexistent Claude status file can still be saved")
func nonexistentClaudeFileCanBeSaved() throws {
    let store = try temporaryStore()
    let settings = MotasSettings(
        claudeCode: ClaudeCodeSettings(
            isEnabled: true,
            statusFilePath: "/tmp/nonexistent/dir/claude-status.json"
        )
    )
    try store.save(settings)
    #expect(try store.load() == settings)
}