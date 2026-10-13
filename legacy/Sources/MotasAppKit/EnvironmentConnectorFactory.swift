import Foundation
import MotasCore

public enum EnvironmentConnectorFactory {
    /// Builds connectors from environment variables only (development default).
    public static func connectors(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        quotaCache: QuotaProbeCache? = nil
    ) -> [any StatusConnector] {
        let resolved = ConnectorConfigurationResolver().resolve(
            settings: .default(),
            persistedDocumentExists: false,
            environment: environment,
            secretStore: EmptySecretStore(),
            quotaCache: quotaCache
        )
        return connectors(from: resolved)
    }

    /// Builds connectors from persisted settings plus environment overrides.
    public static func connectors(
        resolved: ConnectorConfigurationResolver.Resolved,
        quotaCache: QuotaProbeCache? = nil
    ) -> [any StatusConnector] {
        connectors(from: resolved, quotaCache: quotaCache)
    }

    private static func connectors(
        from resolved: ConnectorConfigurationResolver.Resolved,
        quotaCache: QuotaProbeCache? = nil
    ) -> [any StatusConnector] {
        var connectors: [any StatusConnector] = []

        if let config = resolved.claudeCode {
            connectors.append(
                ClaudeCodeConnector(configuration: config)
            )
        }

        if let config = resolved.nineRouter {
            connectors.append(
                NineRouterConnector(configuration: withCache(config, quotaCache))
            )
        }

        if let config = resolved.cliProxyAPI {
            connectors.append(
                CLIProxyAPIConnector(configuration: withCache(config, quotaCache))
            )
        }

        return connectors
    }

    private static func withCache(
        _ config: NineRouterConfiguration,
        _ cache: QuotaProbeCache?
    ) -> NineRouterConfiguration {
        guard let cache, config.quotaCache == nil else { return config }
        return NineRouterConfiguration(
            baseURL: config.baseURL,
            role: config.role,
            isRequiredRoute: config.isRequiredRoute,
            dashboardToken: config.dashboardToken,
            cliToken: config.cliToken,
            quotaCache: cache
        )
    }

    private static func withCache(
        _ config: CLIProxyAPIConfiguration,
        _ cache: QuotaProbeCache?
    ) -> CLIProxyAPIConfiguration {
        guard let cache, config.quotaCache == nil else { return config }
        return CLIProxyAPIConfiguration(
            baseURL: config.baseURL,
            role: config.role,
            isRequiredRoute: config.isRequiredRoute,
            proxyAPIKey: config.proxyAPIKey,
            managementKey: config.managementKey,
            quotaCache: cache
        )
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