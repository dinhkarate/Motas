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

    public var displayName: String { displayName(hint: nil) }

    /// `hint` is the proxy's name for an OpenAI- or Anthropic-compatible node
    /// (`AccountSnapshot.displayHint`); every such node is its own provider id.
    public func displayName(hint: String?) -> String {
        switch rawValue {
        case "codex": "Codex"
        case "claude": "Claude"
        case "antigravity": "Antigravity"
        case "gemini-cli": "Gemini CLI"
        case "xai": "xAI"
        case "openrouter": "OpenRouter"
        case "qoder": "Qoder"
        case "chutes": "Chutes"
        case _ where rawValue.hasPrefix("openai-compatible-"): hint ?? "OpenAI-compatible"
        case _ where rawValue.hasPrefix("anthropic-compatible-"): hint ?? "Anthropic-compatible"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    public static func < (a: Provider, b: Provider) -> Bool { a.rawValue < b.rawValue }
}

/// How a window binds its account: `.limit` always, `.model` only when its
/// group has no `.limit` window, `.detail` never (shown in details only).
public enum WindowRole: String, Codable, Sendable {
    case limit
    case model
    case detail
}

/// One rate-limit window as reported by the provider.
public struct QuotaWindow: Codable, Sendable, Hashable, Identifiable {
    /// Raw key from the proxy.
    public var id: String
    /// Full label for account details ("Gemini · Weekly", "Primary", "Claude Sonnet 4.6").
    public var label: String
    /// Window length, only when the proxy reported it (CPA `limit_window_seconds`).
    public var duration: TimeInterval?
    /// 0…1, clamped.
    public var remainingFraction: Double
    public var resetsAt: Date?
    /// nil = applies to the whole account. Ids, labels and order: `QuotaGroups`.
    public var group: String?
    /// Canonical lane id ("primary", "secondary", "5h", "weekly", "daily"); nil for per-model windows.
    public var period: String?
    public var role: WindowRole

    public init(id: String, label: String, duration: TimeInterval? = nil, remainingFraction: Double, resetsAt: Date? = nil,
                group: String? = nil, period: String? = nil, role: WindowRole = .limit) {
        self.id = id
        self.label = label
        self.duration = duration
        self.remainingFraction = min(max(remainingFraction, 0), 1)
        self.resetsAt = resetsAt
        self.group = group
        self.period = period
        self.role = role
    }

    /// 0.2 windows have no group, period or role.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        remainingFraction = try c.decode(Double.self, forKey: .remainingFraction)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        period = try c.decodeIfPresent(String.self, forKey: .period)
        role = try c.decodeIfPresent(WindowRole.self, forKey: .role) ?? .limit
    }
}

/// What Motas knows about an account's quota. Never invents numbers:
/// `.unavailable` means the proxy/provider exposes no figures,
/// `.failed` means the read was attempted and errored, `.rejected` means two
/// consecutive reads rejected the account's credential.
public enum QuotaReading: Codable, Sendable, Hashable {
    case windows([QuotaWindow])
    case unavailable(String)
    case failed(String)
    case rejected(String)

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

    /// 0.2 also wrote "error"; any unknown value reads as `.active`.
    public init(from decoder: any Decoder) throws {
        self = AccountState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .active
    }
}

/// What the proxy itself last said about an account: 9Router `lastError` /
/// `lastErrorAt`, CPA `status_message`. A label, never a verdict.
public struct ProxyNote: Codable, Sendable, Hashable {
    public var message: String
    public var at: Date?

    public init(message: String, at: Date? = nil) {
        self.message = message
        self.at = at
    }
}

/// Account facts that are not windows. Every field is optional.
public struct UsageExtras: Codable, Sendable, Hashable {
    /// Codex reset credits available. Motas never spends them.
    public var resetCredits: Int?
    /// Qoder `isQuotaExceeded` with no figures.
    public var quotaExceeded: Bool?

    public init(resetCredits: Int? = nil, quotaExceeded: Bool? = nil) {
        self.resetCredits = resetCredits
        self.quotaExceeded = quotaExceeded
    }
}

public struct AccountSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var provider: Provider
    public var label: String
    public var email: String?
    /// Dedupe key across proxies: the Codex account id, else the lowercased email.
    public var identity: String?
    /// Resolved plan: the usage plan, else the last one read, else `metadataPlan`.
    public var plan: String?
    /// Plan from the proxy's account list, which can lag behind usage.
    public var metadataPlan: String?
    public var state: AccountState
    public var quota: QuotaReading
    /// When the windows in `quota` were read.
    public var quotaObservedAt: Date?
    /// Why the latest read failed while older windows are shown.
    public var lastReadError: String?
    public var nextReadAt: Date?
    public var cooldownUntil: Date?
    public var coolingDown: Bool
    /// Models the proxy has locked, with the instant each lock ends.
    public var lockedModels: [String: Date]
    public var proxyNote: ProxyNote?
    public var extras: UsageExtras
    /// Name the proxy gives an OpenAI- or Anthropic-compatible node.
    public var displayHint: String?

    public init(id: String, provider: Provider, label: String, email: String? = nil, identity: String? = nil,
                plan: String? = nil, metadataPlan: String? = nil, state: AccountState, quota: QuotaReading,
                quotaObservedAt: Date? = nil, lastReadError: String? = nil, nextReadAt: Date? = nil,
                cooldownUntil: Date? = nil, coolingDown: Bool = false, lockedModels: [String: Date] = [:],
                proxyNote: ProxyNote? = nil, extras: UsageExtras = UsageExtras(), displayHint: String? = nil) {
        self.id = id
        self.provider = provider
        self.label = label
        self.email = email
        self.identity = identity
        self.plan = plan
        self.metadataPlan = metadataPlan
        self.state = state
        self.quota = quota
        self.quotaObservedAt = quotaObservedAt
        self.lastReadError = lastReadError
        self.nextReadAt = nextReadAt
        self.cooldownUntil = cooldownUntil
        self.coolingDown = coolingDown
        self.lockedModels = lockedModels
        self.proxyNote = proxyNote
        self.extras = extras
        self.displayHint = displayHint
    }

    /// Reads 0.2 accounts too: every newer field has a default, and the old
    /// `stateMessage` is ignored (`proxyNote` replaces it on the next read).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(Provider.self, forKey: .provider)
        label = try c.decode(String.self, forKey: .label)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        identity = try c.decodeIfPresent(String.self, forKey: .identity)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        metadataPlan = try c.decodeIfPresent(String.self, forKey: .metadataPlan)
        state = try c.decode(AccountState.self, forKey: .state)
        quota = try c.decode(QuotaReading.self, forKey: .quota)
        quotaObservedAt = try c.decodeIfPresent(Date.self, forKey: .quotaObservedAt)
        lastReadError = try c.decodeIfPresent(String.self, forKey: .lastReadError)
        nextReadAt = try c.decodeIfPresent(Date.self, forKey: .nextReadAt)
        cooldownUntil = try c.decodeIfPresent(Date.self, forKey: .cooldownUntil)
        coolingDown = try c.decodeIfPresent(Bool.self, forKey: .coolingDown) ?? false
        lockedModels = try c.decodeIfPresent([String: Date].self, forKey: .lockedModels) ?? [:]
        proxyNote = try c.decodeIfPresent(ProxyNote.self, forKey: .proxyNote)
        extras = try c.decodeIfPresent(UsageExtras.self, forKey: .extras) ?? UsageExtras()
        displayHint = try c.decodeIfPresent(String.self, forKey: .displayHint)
    }
}

public enum ProxyHealth: Sendable, Hashable {
    case ok
    /// Keychain did not release the secret: macOS wants the user's approval,
    /// or the read failed (Allow… retries it). Never a proxy failure.
    case needsKeychainAccess
    case failed(ProxyAccessError)

    public var isOK: Bool { self == .ok }
}

extension ProxyHealth: Codable {
    /// Written as `{"kind", "message"?, "until"?}`. 0.2 wrote the synthesized
    /// shapes (`{"ok":{}}`, `{"unreachable":{"_0":"…"}}`…), which still decode.
    private enum CodingKeys: String, CodingKey {
        case kind, message, until
        case ok, needsKeychainAccess, unauthorized, unreachable, failed
    }

    private enum LegacyKeys: String, CodingKey { case _0 }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = try c.decodeIfPresent(String.self, forKey: .kind) else {
            func legacy(_ key: CodingKeys) throws -> String {
                try c.nestedContainer(keyedBy: LegacyKeys.self, forKey: key).decode(String.self, forKey: ._0)
            }
            if c.contains(.ok) { self = .ok }
            else if c.contains(.needsKeychainAccess) { self = .needsKeychainAccess }
            else if c.contains(.unauthorized) { self = .failed(.unauthorized("")) }
            else if c.contains(.unreachable) { self = .failed(.unreachable(try legacy(.unreachable))) }
            else if c.contains(.failed) { self = .failed(.failed(try legacy(.failed))) }
            else { self = .failed(.failed("Unknown")) }
            return
        }
        let message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        switch kind {
        case "ok": self = .ok
        case "needsKeychainAccess": self = .needsKeychainAccess
        case "missingCredential": self = .failed(.missingCredential)
        case "unauthorized": self = .failed(.unauthorized(message))
        case "loginLocked": self = .failed(.loginLocked(until: try c.decode(Date.self, forKey: .until)))
        case "offline": self = .failed(.offline(message))
        case "unreachable": self = .failed(.unreachable(message))
        case "failed": self = .failed(.failed(message))
        default: self = .failed(.failed("Unknown"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let (kind, message): (String, String?) = switch self {
        case .ok: ("ok", nil)
        case .needsKeychainAccess: ("needsKeychainAccess", nil)
        case .failed(.missingCredential): ("missingCredential", nil)
        case .failed(.unauthorized(let m)): ("unauthorized", m)
        case .failed(.loginLocked): ("loginLocked", nil)
        case .failed(.offline(let m)): ("offline", m)
        case .failed(.unreachable(let m)): ("unreachable", m)
        case .failed(.failed(let m)): ("failed", m)
        }
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(message, forKey: .message)
        if case .failed(.loginLocked(let until)) = self { try c.encode(until, forKey: .until) }
    }
}

public struct ProxySnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ProxyKind
    public var fetchedAt: Date
    public var health: ProxyHealth
    public var accounts: [AccountSnapshot]
    /// Last refresh whose listing and reads all succeeded.
    public var lastSuccessAt: Date?
    /// Refreshes in a row that failed; Keychain and missing-credential carries do not count.
    public var consecutiveFailures: Int

    public init(id: UUID, name: String, kind: ProxyKind, fetchedAt: Date, health: ProxyHealth, accounts: [AccountSnapshot],
                lastSuccessAt: Date? = nil, consecutiveFailures: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fetchedAt = fetchedAt
        self.health = health
        self.accounts = accounts
        self.lastSuccessAt = lastSuccessAt
        self.consecutiveFailures = consecutiveFailures
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(ProxyKind.self, forKey: .kind)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        health = try c.decode(ProxyHealth.self, forKey: .health)
        accounts = try c.decode([AccountSnapshot].self, forKey: .accounts)
        lastSuccessAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
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
