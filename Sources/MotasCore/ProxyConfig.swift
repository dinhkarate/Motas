import Foundation

/// How Motas signs in to a proxy.
public enum ProxyAuth: String, Codable, Sendable {
    /// CLIProxyAPI management key (`Authorization: Bearer`).
    case managementKey
    /// 9Router dashboard password, exchanged for the `auth_token` cookie.
    case password
    /// 9Router CLI token (`x-9r-cli-token`): admin-equivalent and permanent.
    case cliToken

    /// What new proxies of `kind` use: the CLI token for 9Router.
    public static func newDefault(for kind: ProxyKind) -> ProxyAuth { kind == .nineRouter ? .cliToken : .managementKey }

    /// A 9Router can run without login, so only a password may be empty.
    var needsSecret: Bool { self != .password }
}

/// A configured remote proxy. Secrets are not stored here; see `SecretStore`.
public struct ProxyConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ProxyKind
    public var baseURL: URL
    public var auth: ProxyAuth
    public var isEnabled: Bool

    /// `auth` defaults to what new proxies use: the CLI token for 9Router.
    public init(id: UUID = UUID(), name: String, kind: ProxyKind, baseURL: URL, auth: ProxyAuth? = nil, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.auth = auth ?? .newDefault(for: kind)
        self.isEnabled = isEnabled
    }

    /// 0.2 settings have no `auth`: they used the dashboard password or the management key.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(ProxyKind.self, forKey: .kind)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        auth = try c.decodeIfPresent(ProxyAuth.self, forKey: .auth) ?? (kind == .nineRouter ? .password : .managementKey)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
    }
}

public protocol ProxyAdapter: Sendable {
    /// One cheap call that lists the proxy's accounts. Throws `ProxyAccessError`;
    /// the caller maps any other error (offline URLErrors → `.offline`, else `.unreachable`).
    func listAccounts() async throws -> [AccountDescriptor]
    /// One account's quota. Account-level outcomes are *returned*. Throws only
    /// proxy-level `ProxyAccessError`s (session/token rejected, login locked,
    /// redirect, offline) — the cycle then stops starting reads.
    func readUsage(_ account: AccountDescriptor, force: Bool) async throws -> UsageReading
}

/// An account as the proxy lists it, before its usage is read.
public struct AccountDescriptor: Sendable, Hashable, Codable {
    /// 9Router connection id / CPA `auth_index`.
    public var id: String
    public var provider: Provider
    /// email ?? displayName ?? name ?? id.
    public var label: String
    public var email: String?
    /// Dedupe key: the Codex account id, else the lowercased email.
    public var identity: String?
    /// Normalised plan from the listing; nil for "" / "unknown".
    public var metadataPlan: String?
    public var isDisabled: Bool
    /// 9Router max(rateLimitedUntil, modelLock___all), CPA next_retry_after / cooldowns[]; only when in the future.
    public var cooldownUntil: Date?
    /// CPA `unavailable == true`, with or without an instant.
    public var coolingDown: Bool
    /// 9Router future `modelLock_<model>` (not `__all`); details only.
    public var lockedModels: [String: Date]
    public var proxyNote: ProxyNote?
    /// 9Router `providerSpecificData.nodeName` for OpenAI- / Anthropic-compatible providers.
    public var displayHint: String?
    public var locator: Locator

    public init(id: String, provider: Provider, label: String, email: String? = nil, identity: String? = nil,
                metadataPlan: String? = nil, isDisabled: Bool = false, cooldownUntil: Date? = nil, coolingDown: Bool = false,
                lockedModels: [String: Date] = [:], proxyNote: ProxyNote? = nil, displayHint: String? = nil,
                locator: Locator = .nineRouter) {
        self.id = id
        self.provider = provider
        self.label = label
        self.email = email
        self.identity = identity
        self.metadataPlan = metadataPlan
        self.isDisabled = isDisabled
        self.cooldownUntil = cooldownUntil
        self.coolingDown = coolingDown
        self.lockedModels = lockedModels
        self.proxyNote = proxyNote
        self.displayHint = displayHint
        self.locator = locator
    }
}

/// What an adapter needs to read the account again.
public enum Locator: Sendable, Hashable, Codable {
    case nineRouter
    case cpa(authIndex: String, codexAccountID: String?, projectID: String?)
}

/// One account read.
public enum UsageReading: Sendable, Hashable {
    case windows([QuotaWindow], plan: String?, extras: UsageExtras)
    /// No figures by design; asked again after `recheckAfter`.
    case unavailable(String, recheckAfter: TimeInterval, extras: UsageExtras)
    case failed(UsageFailure)
}

public struct UsageFailure: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case transient
        case rateLimited(until: Date?)
        case credentialRejected
    }

    public var kind: Kind
    /// Short, human, never contains a secret.
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public static func transient(_ message: String) -> UsageFailure { UsageFailure(kind: .transient, message: message) }
    public static func rateLimited(until: Date?, _ message: String) -> UsageFailure {
        UsageFailure(kind: .rateLimited(until: until), message: message)
    }
    public static func credentialRejected(_ message: String) -> UsageFailure {
        UsageFailure(kind: .credentialRejected, message: message)
    }
}

/// A problem with a proxy as a whole; account-level problems are `UsageFailure`s.
public enum ProxyAccessError: Error, Sendable, Hashable, Codable {
    case missingCredential
    case unauthorized(String)
    case loginLocked(until: Date)
    /// URLError notConnectedToInternet / networkConnectionLost / dataNotAllowed / internationalRoamingOff.
    case offline(String)
    case unreachable(String)
    case failed(String)

    /// Any error from an adapter: offline URLErrors → `.offline`, other non-`ProxyAccessError`s → `.unreachable`.
    init(_ error: any Error) {
        switch error {
        case let error as ProxyAccessError: self = error
        case let error where isOffline(error): self = .offline(describe(error))
        default: self = .unreachable(describe(error))
        }
    }
}

public enum ProxyAdapters {
    public static func make(_ config: ProxyConfig, secret: String?, http: any HTTPClient,
                            now: @escaping @Sendable () -> Date = Date.init) -> any ProxyAdapter {
        switch config.kind {
        case .cliProxyAPI: CLIProxyAPIAdapter(config: config, managementKey: secret, http: http, now: now)
        case .nineRouter: NineRouterAdapter(config: config, secret: secret, http: http, now: now)
        }
    }
}

/// Runs `transform` over `items` with at most `limit` in flight, preserving order.
func boundedMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ transform: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        func addNext() {
            guard next < items.count else { return }
            let index = next, item = items[index]
            next += 1
            group.addTask { (index, await transform(item)) }
        }
        for _ in 0..<min(limit, items.count) { addNext() }
        while let (index, value) = await group.next() {
            results[index] = value
            addNext()
        }
        return results.map { $0! }
    }
}

extension URL {
    func appendingAPIPath(_ path: String) -> URL {
        var base = absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)!
    }
}

func describe(_ error: Error) -> String {
    if let url = error as? URLError {
        switch url.code {
        case .timedOut: return "Timed out"
        case .cannotConnectToHost: return "Connection refused"
        case .cannotFindHost, .dnsLookupFailed: return "Host not found"
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return "Network unavailable"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS error"
        default: return url.localizedDescription
        }
    }
    return error.localizedDescription
}

/// The Mac itself is offline, so the error says nothing about the proxy.
func isOffline(_ error: any Error) -> Bool {
    guard let error = error as? URLError else { return false }
    return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
}
