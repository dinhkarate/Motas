import Foundation
import Testing
@testable import MotasCore

/// In-memory secret store fake for tests (reference type for mutable injection).
private final class MemorySecretStore: ConnectorSecretStore, @unchecked Sendable {
    var dict: [ConnectorSecretKey: String] = [:]
    var failReads = false

    init() {}

    func value(for key: ConnectorSecretKey) throws -> String? {
        if failReads {
            struct TestError: Error {}
            throw TestError()
        }
        return dict[key]
    }
    func set(_ value: String, for key: ConnectorSecretKey) throws {
        dict[key] = value
    }
    func removeValue(for key: ConnectorSecretKey) throws {
        dict.removeValue(forKey: key)
    }
    func containsValue(for key: ConnectorSecretKey) throws -> Bool {
        if failReads {
            struct TestError: Error {}
            throw TestError()
        }
        return dict[key] != nil
    }
}

private func makeResolver(
    environment: [String: String],
    settings: MotasSettings = .default(),
    persistedExists: Bool = true,
    store: ConnectorSecretStore = MemorySecretStore()
) -> ConnectorConfigurationResolver.Resolved {
    ConnectorConfigurationResolver().resolve(
        settings: settings,
        persistedDocumentExists: persistedExists,
        environment: environment,
        secretStore: store
    )
}

@Test("Persisted Claude settings produce ClaudeCodeConfiguration")
func persistedClaude() {
    let settings = MotasSettings(
        claudeCode: ClaudeCodeSettings(isEnabled: true)
    )
    let resolved = makeResolver(environment: [:], settings: settings)
    #expect(resolved.claudeCode != nil)
    #expect(resolved.claudeCode?.role == .primary)
}

@Test("Persisted 9Router resolves Keychain dashboard and CLI tokens")
func persistedNineRouterResolvesKeychainTokens() {
    let store = MemorySecretStore()
    store.dict[.nineRouterDashboardToken] = "dashboard-key"
    store.dict[.nineRouterCLIToken] = "cli-key"
    let resolved = makeResolver(
        environment: [:],
        settings: MotasSettings(nineRouter: NineRouterSettings(isEnabled: true)),
        store: store
    )

    #expect(resolved.nineRouter?.dashboardToken == "dashboard-key")
    #expect(resolved.nineRouter?.cliToken == "cli-key")
}

@Test("Environment-only behavior matches documented behavior")
func environmentOnly() {
    let resolved = makeResolver(
        environment: [
            "MOTAS_9ROUTER_URL": "http://localhost:20128",
            "MOTAS_CLIPROXYAPI_URL": "http://localhost:8317",
        ]
    )
    #expect(resolved.nineRouter?.role == .primary)
    #expect(resolved.nineRouter?.isRequiredRoute == true)
    #expect(resolved.cliProxyAPI?.role == .fallback)
}

@Test("Environment URL overrides persisted URL")
func environmentOverridesURL() {
    let settings = MotasSettings(
        nineRouter: NineRouterSettings(isEnabled: true, baseURL: URL(string: "http://old:1")!)
    )
    let resolved = makeResolver(
        environment: ["MOTAS_9ROUTER_URL": "http://new:2"],
        settings: settings
    )
    #expect(resolved.nineRouter?.baseURL.absoluteString == "http://new:2")
}

@Test("Environment secret overrides Keychain")
func environmentSecretOverridesKeychain() {
    let store = MemorySecretStore()
    store.dict[.nineRouterDashboardToken] = "keychain-key"
    let resolved = makeResolver(
        environment: ["MOTAS_9ROUTER_DASHBOARD_TOKEN": "env-key"],
        settings: MotasSettings(nineRouter: NineRouterSettings(isEnabled: true)),
        store: store
    )
    #expect(resolved.nineRouter?.dashboardToken == "env-key")
}

@Test("Environment secret override skips Keychain reads")
func environmentSecretSkipsKeychain() {
    let store = MemorySecretStore()
    store.failReads = true
    let resolved = makeResolver(
        environment: [
            "MOTAS_9ROUTER_DASHBOARD_TOKEN": "env-key",
            "MOTAS_9ROUTER_CLI_TOKEN": "env-cli",
        ],
        settings: MotasSettings(nineRouter: NineRouterSettings(isEnabled: true)),
        store: store
    )

    #expect(resolved.nineRouter?.dashboardToken == "env-key")
    #expect(resolved.nineRouter?.cliToken == "env-cli")
    #expect(resolved.issues.isEmpty)
}

@Test("Empty environment secret falls back to Keychain")
func emptyEnvFallsBackToKeychain() {
    let store = MemorySecretStore()
    store.dict[.nineRouterDashboardToken] = "keychain-key"
    let resolved = makeResolver(
        environment: ["MOTAS_9ROUTER_DASHBOARD_TOKEN": ""],
        settings: MotasSettings(nineRouter: NineRouterSettings(isEnabled: true)),
        store: store
    )
    #expect(resolved.nineRouter?.dashboardToken == "keychain-key")
}

@Test("MOTAS_CLAUDE_CODE_ENABLED=0 disables persisted Claude")
func claudeEnabledZeroDisables() {
    let resolved = makeResolver(
        environment: ["MOTAS_CLAUDE_CODE_ENABLED": "0"],
        settings: MotasSettings(claudeCode: ClaudeCodeSettings(isEnabled: true))
    )
    #expect(resolved.claudeCode == nil)
}

@Test("CLIProxyAPI primary when 9Router absent")
func cliProxyPrimaryWithoutNineRouter() {
    let resolved = makeResolver(
        environment: ["MOTAS_CLIPROXYAPI_URL": "http://localhost:8317"]
    )
    #expect(resolved.cliProxyAPI?.role == .primary)
}

@Test("Credential-bearing environment endpoints are rejected safely")
func credentialEnvironmentURLsRejected() {
    let persistedURL = URL(string: "http://saved:8317")!
    let resolved = makeResolver(
        environment: [
            "MOTAS_CLIPROXYAPI_URL": "http://user:secret@localhost:8317?api_key=secret",
        ],
        settings: MotasSettings(
            cliProxyAPI: CLIProxyAPISettings(isEnabled: true, baseURL: persistedURL)
        )
    )

    #expect(resolved.cliProxyAPI?.baseURL == persistedURL)
    #expect(resolved.issues.count == 1)
    #expect(!resolved.issues[0].message.contains("secret"))
}

@Test("Disabled connectors do not query Keychain")
func disabledConnectorSkipsKeychain() {
    let store = MemorySecretStore()
    store.failReads = true
    // 9Router disabled, so resolver must not call value(for:) for its secrets.
    let resolved = makeResolver(
        environment: [:],
        settings: MotasSettings(claudeCode: ClaudeCodeSettings(isEnabled: false)),
        store: store
    )
    #expect(resolved.issues.isEmpty)
}