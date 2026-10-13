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
    case invalidStatusFilePath
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
public struct MotasSettings: Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public static let defaultAutomaticRefreshInterval: TimeInterval = 300
    public static let defaultQuotaProbeInterval: TimeInterval = 600

    public var schemaVersion: Int
    public var automaticRefreshEnabled: Bool
    public var automaticRefreshInterval: TimeInterval
    public var quotaProbeEnabled: Bool
    public var quotaProbeInterval: TimeInterval
    public var showMenuBarPercentage: Bool
    public var tintMenuBarWhenLow: Bool
    public var launchAtLogin: Bool
    public var compactPanel: Bool
    public var claudeCode: ClaudeCodeSettings
    public var nineRouter: NineRouterSettings
    public var cliProxyAPI: CLIProxyAPISettings

    public init(
        schemaVersion: Int = MotasSettings.currentSchemaVersion,
        automaticRefreshEnabled: Bool = true,
        automaticRefreshInterval: TimeInterval = MotasSettings.defaultAutomaticRefreshInterval,
        quotaProbeEnabled: Bool = true,
        quotaProbeInterval: TimeInterval = MotasSettings.defaultQuotaProbeInterval,
        showMenuBarPercentage: Bool = true,
        tintMenuBarWhenLow: Bool = true,
        launchAtLogin: Bool = false,
        compactPanel: Bool = true,
        claudeCode: ClaudeCodeSettings = .default(),
        nineRouter: NineRouterSettings = .default(),
        cliProxyAPI: CLIProxyAPISettings = .default()
    ) {
        self.schemaVersion = schemaVersion
        self.automaticRefreshEnabled = automaticRefreshEnabled
        self.automaticRefreshInterval = automaticRefreshInterval
        self.quotaProbeEnabled = quotaProbeEnabled
        self.quotaProbeInterval = quotaProbeInterval
        self.showMenuBarPercentage = showMenuBarPercentage
        self.tintMenuBarWhenLow = tintMenuBarWhenLow
        self.launchAtLogin = launchAtLogin
        self.compactPanel = compactPanel
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
        let expandedStatusPath = (claudeCode.statusFilePath as NSString).expandingTildeInPath
        guard expandedStatusPath.hasPrefix("/") else {
            throw ConnectorSettingsValidationError.invalidStatusFilePath
        }
        result.claudeCode.statusFilePath =
            URL(
                fileURLWithPath: expandedStatusPath
            ).standardizedFileURL.path
        result.nineRouter.baseURL = try ConnectorEndpointRule.validate(
            baseURL: nineRouter.baseURL,
            label: "9Router endpoint"
        )
        result.cliProxyAPI.baseURL = try ConnectorEndpointRule.validate(
            baseURL: cliProxyAPI.baseURL,
            label: "CLIProxyAPI endpoint",
            allowedSuffixes: ["/v1", "/v0/management"]
        )
        result.automaticRefreshInterval = min(max(result.automaticRefreshInterval, 60), 3600)
        result.quotaProbeInterval = min(max(result.quotaProbeInterval, 300), 7200)
        result.schemaVersion = MotasSettings.currentSchemaVersion
        return result
    }
}

extension MotasSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case automaticRefreshEnabled
        case automaticRefreshInterval
        case quotaProbeEnabled
        case quotaProbeInterval
        case showMenuBarPercentage
        case tintMenuBarWhenLow
        case launchAtLogin
        case compactPanel
        case claudeCode
        case nineRouter
        case cliProxyAPI
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        automaticRefreshEnabled =
            (try? container.decodeIfPresent(Bool.self, forKey: .automaticRefreshEnabled)) ?? true
        automaticRefreshInterval =
            (try? container.decodeIfPresent(TimeInterval.self, forKey: .automaticRefreshInterval))
            ?? MotasSettings.defaultAutomaticRefreshInterval
        quotaProbeEnabled =
            (try? container.decodeIfPresent(Bool.self, forKey: .quotaProbeEnabled)) ?? true
        quotaProbeInterval =
            (try? container.decodeIfPresent(TimeInterval.self, forKey: .quotaProbeInterval))
            ?? MotasSettings.defaultQuotaProbeInterval
        showMenuBarPercentage =
            (try? container.decodeIfPresent(Bool.self, forKey: .showMenuBarPercentage)) ?? true
        tintMenuBarWhenLow =
            (try? container.decodeIfPresent(Bool.self, forKey: .tintMenuBarWhenLow)) ?? true
        launchAtLogin = (try? container.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false
        compactPanel = (try? container.decodeIfPresent(Bool.self, forKey: .compactPanel)) ?? true
        claudeCode =
            (try? container.decodeIfPresent(ClaudeCodeSettings.self, forKey: .claudeCode))
            ?? .default()
        nineRouter =
            (try? container.decodeIfPresent(NineRouterSettings.self, forKey: .nineRouter))
            ?? .default()
        cliProxyAPI =
            (try? container.decodeIfPresent(CLIProxyAPISettings.self, forKey: .cliProxyAPI))
            ?? .default()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(MotasSettings.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(automaticRefreshEnabled, forKey: .automaticRefreshEnabled)
        try container.encode(automaticRefreshInterval, forKey: .automaticRefreshInterval)
        try container.encode(quotaProbeEnabled, forKey: .quotaProbeEnabled)
        try container.encode(quotaProbeInterval, forKey: .quotaProbeInterval)
        try container.encode(showMenuBarPercentage, forKey: .showMenuBarPercentage)
        try container.encode(tintMenuBarWhenLow, forKey: .tintMenuBarWhenLow)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(compactPanel, forKey: .compactPanel)
        try container.encode(claudeCode, forKey: .claudeCode)
        try container.encode(nineRouter, forKey: .nineRouter)
        try container.encode(cliProxyAPI, forKey: .cliProxyAPI)
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
            guard allowedSuffixes.contains(path) else {
                throw ConnectorSettingsValidationError.unsupportedPath(label)
            }
            path = ""
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let normalized = components?.url else {
            throw ConnectorSettingsValidationError.invalidScheme(label)
        }
        return normalized
    }
}
