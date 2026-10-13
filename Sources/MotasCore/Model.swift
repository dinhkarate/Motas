import Foundation

/// The kinds of remote proxy Motas can read.
public enum ProxyKind: String, Codable, Sendable, CaseIterable {
    case cliProxyAPI
    case nineRouter

    public var displayName: String {
        switch self {
        case .cliProxyAPI: "CLIProxyAPI"
        case .nineRouter: "9Router"
        }
    }

    public var defaultBaseURL: URL {
        switch self {
        case .cliProxyAPI: URL(string: "http://127.0.0.1:8317")!
        case .nineRouter: URL(string: "http://127.0.0.1:20128")!
        }
    }
}

/// An upstream AI provider an account belongs to. Proxies use free-form ids
/// ("codex", "antigravity", "gemini-cli"…); unknown ids are kept verbatim.
public struct Provider: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }

    public static let codex = Provider(rawValue: "codex")
    public static let claude = Provider(rawValue: "claude")
    public static let antigravity = Provider(rawValue: "antigravity")
    public static let geminiCLI = Provider(rawValue: "gemini-cli")

    public var displayName: String {
        switch rawValue {
        case "codex": "Codex"
        case "claude": "Claude"
        case "antigravity": "Antigravity"
        case "gemini-cli": "Gemini CLI"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    public static func < (a: Provider, b: Provider) -> Bool { a.rawValue < b.rawValue }
}

/// One rate-limit window as reported by the provider.
public struct QuotaWindow: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    /// Window length when the provider reports it.
    public var duration: TimeInterval?
    /// 0…1, clamped.
    public var remainingFraction: Double
    public var resetsAt: Date?

    public init(id: String, label: String, duration: TimeInterval? = nil, remainingFraction: Double, resetsAt: Date? = nil) {
        self.id = id
        self.label = label
        self.duration = duration
        self.remainingFraction = min(max(remainingFraction, 0), 1)
        self.resetsAt = resetsAt
    }
}

/// What Motas knows about an account's quota. Never invents numbers:
/// `.unavailable` means the proxy/provider exposes no figures,
/// `.failed` means the read was attempted and errored.
public enum QuotaReading: Codable, Sendable, Hashable {
    case windows([QuotaWindow])
    case unavailable(String)
    case failed(String)

    public var windows: [QuotaWindow] {
        if case .windows(let w) = self { return w }
        return []
    }

    /// The account is limited by its tightest window.
    public var effectiveRemaining: Double? {
        windows.map(\.remainingFraction).min()
    }
}

public enum AccountState: String, Codable, Sendable {
    case active
    case disabled
    case error
}

public struct AccountSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var provider: Provider
    public var label: String
    public var plan: String?
    public var state: AccountState
    public var stateMessage: String?
    public var quota: QuotaReading

    public init(id: String, provider: Provider, label: String, plan: String? = nil, state: AccountState, stateMessage: String? = nil, quota: QuotaReading) {
        self.id = id
        self.provider = provider
        self.label = label
        self.plan = plan
        self.state = state
        self.stateMessage = stateMessage
        self.quota = quota
    }
}

public enum ProxyHealth: Codable, Sendable, Hashable {
    case ok
    case unauthorized
    /// The secret is in Keychain but macOS wants the user to approve access.
    case needsKeychainAccess
    case unreachable(String)
    case failed(String)

    public var isOK: Bool { self == .ok }
}

public struct ProxySnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ProxyKind
    public var fetchedAt: Date
    public var health: ProxyHealth
    public var accounts: [AccountSnapshot]

    public init(id: UUID, name: String, kind: ProxyKind, fetchedAt: Date, health: ProxyHealth, accounts: [AccountSnapshot]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fetchedAt = fetchedAt
        self.health = health
        self.accounts = accounts
    }
}

public struct Snapshot: Codable, Sendable, Hashable {
    public var fetchedAt: Date
    public var proxies: [ProxySnapshot]

    public init(fetchedAt: Date, proxies: [ProxySnapshot]) {
        self.fetchedAt = fetchedAt
        self.proxies = proxies
    }

    public static let empty = Snapshot(fetchedAt: .distantPast, proxies: [])
}
