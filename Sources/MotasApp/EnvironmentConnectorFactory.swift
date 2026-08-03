import Foundation
import MotasCore

enum EnvironmentConnectorFactory {
    /// Builds connectors from environment variables only (development default).
    static func connectors(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [any StatusConnector] {
        let resolved = ConnectorConfigurationResolver().resolve(
            settings: .default(),
            persistedDocumentExists: false,
            environment: environment,
            secretStore: EmptySecretStore()
        )
        return connectors(from: resolved, secretStore: EmptySecretStore())
    }

    /// Builds connectors from persisted settings plus environment overrides.
    static func connectors(
        resolved: ConnectorConfigurationResolver.Resolved
    ) -> [any StatusConnector] {
        connectors(from: resolved, secretStore: EmptySecretStore())
    }

    private static func connectors(
        from resolved: ConnectorConfigurationResolver.Resolved,
        secretStore: ConnectorSecretStore
    ) -> [any StatusConnector] {
        var connectors: [any StatusConnector] = []

        if let config = resolved.claudeCode {
            connectors.append(
                ClaudeCodeConnector(configuration: config)
            )
        }

        if let config = resolved.nineRouter {
            connectors.append(
                NineRouterConnector(configuration: config)
            )
        }

        if let config = resolved.cliProxyAPI {
            connectors.append(
                CLIProxyAPIConnector(configuration: config)
            )
        }

        return connectors
    }
}

/// An empty, read-only secret store used for environment-only resolution where
/// no Keychain interactions should occur.
private struct EmptySecretStore: ConnectorSecretStore {
    func value(for key: ConnectorSecretKey) throws -> String? { nil }
    func set(_ value: String, for key: ConnectorSecretKey) throws {}
    func removeValue(for key: ConnectorSecretKey) throws {}
    func containsValue(for key: ConnectorSecretKey) throws -> Bool { false }
}