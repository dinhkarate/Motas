import Foundation

/// Where a connector's enabled state or a secret came from.
public enum ConnectorConfigurationSource: String, Sendable, Equatable {
    case environment
    case keychain
    case persisted
    case disabled
    case `default`
}

/// A sanitized, user-presentable resolution note.
public struct ConfigurationResolutionIssue: Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Where an individual secret came from, for Settings status labels.
public enum SecretSource: String, Sendable, Equatable {
    case environment
    case keychain
    case unset
}

/// Per-connector source labels resolved from settings/environment/Keychain.
public struct ConnectorSourceLabels: Sendable, Equatable {
    public let claudeCodeEnabled: ConnectorConfigurationSource
    public let nineRouterEnabled: ConnectorConfigurationSource
    public let cliProxyAPIEnabled: ConnectorConfigurationSource
    public let nineRouterDashboard: SecretSource
    public let nineRouterCLI: SecretSource
    public let cliProxyAPIKey: SecretSource
    public let cliProxyAPIManagementKey: SecretSource

    public init(
        claudeCodeEnabled: ConnectorConfigurationSource,
        nineRouterEnabled: ConnectorConfigurationSource,
        cliProxyAPIEnabled: ConnectorConfigurationSource,
        nineRouterDashboard: SecretSource = .unset,
        nineRouterCLI: SecretSource = .unset,
        cliProxyAPIKey: SecretSource = .unset,
        cliProxyAPIManagementKey: SecretSource = .unset
    ) {
        self.claudeCodeEnabled = claudeCodeEnabled
        self.nineRouterEnabled = nineRouterEnabled
        self.cliProxyAPIEnabled = cliProxyAPIEnabled
        self.nineRouterDashboard = nineRouterDashboard
        self.nineRouterCLI = nineRouterCLI
        self.cliProxyAPIKey = cliProxyAPIKey
        self.cliProxyAPIManagementKey = cliProxyAPIManagementKey
    }
}

/// A resolved secret pair.
private struct ResolvedSecret {
    let value: String?
    let source: SecretSource
}

/// Resolves which connectors to build from persisted settings, environment and
/// the Keychain. Precedence: explicit environment > persisted/Keychain > default.
///
/// The resolver is pure aside from the injected secret store; it never reads
/// `ProcessInfo` directly.
public struct ConnectorConfigurationResolver: Sendable {
    public init() {}

    public struct Resolved: Sendable {
        public let claudeCode: ClaudeCodeConfiguration?
        public let nineRouter: NineRouterConfiguration?
        public let cliProxyAPI: CLIProxyAPIConfiguration?
        public let issues: [ConfigurationResolutionIssue]
        public let labels: ConnectorSourceLabels

        public init(
            claudeCode: ClaudeCodeConfiguration?,
            nineRouter: NineRouterConfiguration?,
            cliProxyAPI: CLIProxyAPIConfiguration?,
            issues: [ConfigurationResolutionIssue],
            labels: ConnectorSourceLabels
        ) {
            self.claudeCode = claudeCode
            self.nineRouter = nineRouter
            self.cliProxyAPI = cliProxyAPI
            self.issues = issues
            self.labels = labels
        }
    }

    public func resolve(
        settings: MotasSettings,
        persistedDocumentExists: Bool,
        environment: [String: String],
        secretStore: ConnectorSecretStore,
        quotaCache: QuotaProbeCache? = nil
    ) -> Resolved {
        var issues: [ConfigurationResolutionIssue] = []

        func maybeEnv(_ key: String) -> String? {
            environment[key].flatMap { $0.nonEmpty }
        }

        func readSecret(
            environmentKey: String,
            keychainKey: ConnectorSecretKey,
            connectorEnabled: Bool
        ) -> ResolvedSecret {
            if let envValue = maybeEnv(environmentKey) {
                return ResolvedSecret(value: envValue, source: .environment)
            }
            guard connectorEnabled else { return ResolvedSecret(value: nil, source: .unset) }
            do {
                if try secretStore.containsValue(for: keychainKey) {
                    let value = try secretStore.value(for: keychainKey)
                    return ResolvedSecret(value: value, source: .keychain)
                }
                return ResolvedSecret(value: nil, source: .unset)
            } catch {
                issues.append(
                    ConfigurationResolutionIssue(
                        "A stored credential could not be read and is treated as unset."
                    )
                )
                return ResolvedSecret(value: nil, source: .unset)
            }
        }

        // ---- Claude Code (no secrets in storage). ----
        let claudeEnabled: Bool
        let claudeSource: ConnectorConfigurationSource
        switch environment["MOTAS_CLAUDE_CODE_ENABLED"] {
        case "1":
            claudeEnabled = true
            claudeSource = .environment
        case "0":
            claudeEnabled = false
            claudeSource = .environment
        default:
            claudeEnabled = settings.claudeCode.isEnabled
            claudeSource = claudeEnabled ? .persisted : .disabled
        }

        let claudeStatusPath = maybeEnv("MOTAS_CLAUDE_STATUS_FILE")
            ?? settings.claudeCode.statusFilePath
        let claudeCode = claudeEnabled
            ? ClaudeCodeConfiguration(
                statusFileURL: URL(
                    fileURLWithPath: (claudeStatusPath as NSString).expandingTildeInPath
                )
            )
            : nil

        // ---- 9Router. ----
        let nineRouterEnabled: Bool
        let nineRouterURL: URL
        let nineRouterSource: ConnectorConfigurationSource

        if let rawURL = maybeEnv("MOTAS_9ROUTER_URL") {
            if let url = Self.validatedEndpointURL(
                rawURL,
                label: "9Router environment endpoint"
            ) {
                nineRouterEnabled = true
                nineRouterURL = url
                nineRouterSource = .environment
            } else {
                issues.append(
                    ConfigurationResolutionIssue(
                        "MOTAS_9ROUTER_URL is not a valid absolute HTTP(S) URL and is ignored."
                    )
                )
                nineRouterEnabled = settings.nineRouter.isEnabled
                nineRouterURL = settings.nineRouter.baseURL
                nineRouterSource = nineRouterEnabled ? .persisted : .disabled
            }
        } else {
            nineRouterEnabled = settings.nineRouter.isEnabled
            nineRouterURL = settings.nineRouter.baseURL
            nineRouterSource = nineRouterEnabled ? .persisted : .disabled
        }

        let dashboard = readSecret(
            environmentKey: "MOTAS_9ROUTER_DASHBOARD_TOKEN",
            keychainKey: .nineRouterDashboardToken,
            connectorEnabled: nineRouterEnabled
        )
        let cliToken = readSecret(
            environmentKey: "MOTAS_9ROUTER_CLI_TOKEN",
            keychainKey: .nineRouterCLIToken,
            connectorEnabled: nineRouterEnabled
        )

        let nineRouter = nineRouterEnabled
            ? NineRouterConfiguration(
                baseURL: nineRouterURL,
                role: .primary,
                isRequiredRoute: true,
                dashboardToken: dashboard.value,
                cliToken: cliToken.value,
                quotaCache: quotaCache
            )
            : nil

        // ---- CLIProxyAPI. ----
        let cliProxyEnabled: Bool
        let cliProxyURL: URL
        let cliProxySource: ConnectorConfigurationSource

        if let rawURL = maybeEnv("MOTAS_CLIPROXYAPI_URL") {
            if let url = Self.validatedEndpointURL(
                rawURL,
                label: "CLIProxyAPI environment endpoint",
                allowedSuffixes: ["/v1", "/v0/management"]
            ) {
                cliProxyEnabled = true
                cliProxyURL = url
                cliProxySource = .environment
            } else {
                issues.append(
                    ConfigurationResolutionIssue(
                        "MOTAS_CLIPROXYAPI_URL is not a valid absolute HTTP(S) URL and is ignored."
                    )
                )
                cliProxyEnabled = settings.cliProxyAPI.isEnabled
                cliProxyURL = settings.cliProxyAPI.baseURL
                cliProxySource = cliProxyEnabled ? .persisted : .disabled
            }
        } else {
            cliProxyEnabled = settings.cliProxyAPI.isEnabled
            cliProxyURL = settings.cliProxyAPI.baseURL
            cliProxySource = cliProxyEnabled ? .persisted : .disabled
        }

        let proxyKey = readSecret(
            environmentKey: "MOTAS_CLIPROXYAPI_KEY",
            keychainKey: .cliProxyAPIProxyKey,
            connectorEnabled: cliProxyEnabled
        )
        let managementKey = readSecret(
            environmentKey: "MOTAS_CLIPROXYAPI_MANAGEMENT_KEY",
            keychainKey: .cliProxyAPIManagementKey,
            connectorEnabled: cliProxyEnabled
        )

        // CLIProxyAPI is the fallback when 9Router is also enabled.
        let isFallback = cliProxyEnabled && nineRouterEnabled
        let cliProxyAPI = cliProxyEnabled
            ? CLIProxyAPIConfiguration(
                baseURL: cliProxyURL,
                role: isFallback ? .fallback : .primary,
                isRequiredRoute: !isFallback,
                proxyAPIKey: proxyKey.value,
                managementKey: managementKey.value,
                quotaCache: quotaCache
            )
            : nil

        _ = persistedDocumentExists

        return Resolved(
            claudeCode: claudeCode,
            nineRouter: nineRouter,
            cliProxyAPI: cliProxyAPI,
            issues: issues,
            labels: ConnectorSourceLabels(
                claudeCodeEnabled: claudeSource,
                nineRouterEnabled: nineRouterSource,
                cliProxyAPIEnabled: cliProxySource,
                nineRouterDashboard: dashboard.source,
                nineRouterCLI: cliToken.source,
                cliProxyAPIKey: proxyKey.source,
                cliProxyAPIManagementKey: managementKey.source
            )
        )
    }

    public static func validatedEndpointURL(
        _ value: String,
        label: String,
        allowedSuffixes: [String] = []
    ) -> URL? {
        guard let url = URL(string: value) else { return nil }
        return try? ConnectorEndpointRule.validate(
            baseURL: url,
            label: label,
            allowedSuffixes: allowedSuffixes
        )
    }
}