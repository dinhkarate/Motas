import Foundation

/// Stable identifiers for Keychain secret items.
///
/// These raw values double as Keychain account names and must not be casually
/// renamed once users have stored credentials.
public enum ConnectorSecretKey: String, Sendable, Codable, CaseIterable {
    case nineRouterDashboardToken = "9router.dashboard-token"
    case nineRouterCLIToken = "9router.cli-token"
    case cliProxyAPIProxyKey = "cliproxyapi.proxy-api-key"
    case cliProxyAPIManagementKey = "cliproxyapi.management-key"
}

public enum ConnectorSettingsValidationError: Error, Equatable {
    case invalidScheme(String)
    case missingHost(String)
    case embeddedCredentials(String)
    case unsupportedQueryOrFragment(String)
    case unsupportedPath(String)
}

/// Secret-free Claude Code settings.
public struct ClaudeCodeSettings: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var statusFilePath: String

    public static let defaultStatusFilePath =
        "~/Library/Application Support/Motas/claude-code-status.json"

    public init(
        isEnabled: Bool = false,
        statusFilePath: String = ClaudeCodeSettings.defaultStatusFilePath
    ) {
        self.isEnabled = isEnabled
        self.statusFilePath = statusFilePath
    }

    public static func `default`() -> ClaudeCodeSettings {
        ClaudeCodeSettings()
    }
}

/// Secret-free 9Router settings.
public struct NineRouterSettings: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var baseURL: URL

    public static let defaultURL = URL(string: "http://localhost:20128")!

    public init(isEnabled: Bool = false, baseURL: URL = NineRouterSettings.defaultURL) {
        self.isEnabled = isEnabled
        self.baseURL = baseURL
    }

    public static func `default`() -> NineRouterSettings {
        NineRouterSettings()
    }
}

/// Secret-free CLIProxyAPI settings.
public struct CLIProxyAPISettings: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var baseURL: URL

    public static let defaultURL = URL(string: "http://localhost:8317")!

    public init(isEnabled: Bool = false, baseURL: URL = CLIProxyAPISettings.defaultURL) {
        self.isEnabled = isEnabled
        self.baseURL = baseURL
    }

    public static func `default`() -> CLIProxyAPISettings {
        CLIProxyAPISettings()
    }
}

/// The persisted, non-secret connector configuration contract.
public struct MotasSettings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var automaticRefreshEnabled: Bool
    public var claudeCode: ClaudeCodeSettings
    public var nineRouter: NineRouterSettings
    public var cliProxyAPI: CLIProxyAPISettings

    public init(
        schemaVersion: Int = MotasSettings.currentSchemaVersion,
        automaticRefreshEnabled: Bool = true,
        claudeCode: ClaudeCodeSettings = .default(),
        nineRouter: NineRouterSettings = .default(),
        cliProxyAPI: CLIProxyAPISettings = .default()
    ) {
        self.schemaVersion = schemaVersion
        self.automaticRefreshEnabled = automaticRefreshEnabled
        self.claudeCode = claudeCode
        self.nineRouter = nineRouter
        self.cliProxyAPI = cliProxyAPI
    }

    public static func `default`() -> MotasSettings {
        MotasSettings()
    }

    /// Validates and returns endpoints the user entered through Settings.
    ///
    /// Rejects credentials embedded in URLs and only accepts paths the existing
    /// connectors know how to normalize.
    public func validated() throws -> MotasSettings {
        var result = self
        result.nineRouter.baseURL = try ConnectorEndpointRule.validate(
            baseURL: nineRouter.baseURL,
            label: "9Router endpoint"
        )
        result.cliProxyAPI.baseURL = try ConnectorEndpointRule.validate(
            baseURL: cliProxyAPI.baseURL,
            label: "CLIProxyAPI endpoint",
            allowedSuffixes: ["/v1", "/v0/management"]
        )
        return result
    }
}

/// Validation rules for Settings-entered proxy endpoints.
public enum ConnectorEndpointRule {
    /// Validates a proxy base URL, stripping a supported path suffix when present.
    ///
    /// - Parameters:
    ///   - baseURL: the endpoint to validate.
    ///   - label: human-readable name used only for error context.
    ///   - allowedSuffixes: path suffixes that are stripped and accepted.
    public static func validate(
        baseURL: URL,
        label: String = "endpoint",
        allowedSuffixes: [String] = []
    ) throws -> URL {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw ConnectorSettingsValidationError.invalidScheme(label)
        }
        guard baseURL.host?.isEmpty == false else {
            throw ConnectorSettingsValidationError.missingHost(label)
        }
        guard baseURL.user == nil, baseURL.password == nil else {
            throw ConnectorSettingsValidationError.embeddedCredentials(label)
        }
        guard baseURL.query == nil, baseURL.fragment == nil else {
            throw ConnectorSettingsValidationError.unsupportedQueryOrFragment(label)
        }

        var path = baseURL.path
        if path == "/" {
            path = ""
        }
        if !path.isEmpty {
            guard let matched = allowedSuffixes.first(where: { path.hasSuffix($0) }) else {
                throw ConnectorSettingsValidationError.unsupportedPath(label)
            }
            path = String(path.dropLast(matched.count))
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let normalized = components?.url else {
            throw ConnectorSettingsValidationError.invalidScheme(label)
        }
        return normalized
    }
}
