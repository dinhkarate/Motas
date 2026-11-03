import Foundation

/// One notification. `identifier` is deterministic, so a newer alert of the
/// same kind and key replaces the older one in Notification Center.
public struct QuotaAlert: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case poolLow, poolExhausted, poolAvailable, proxyDown, proxyBack, accountsRejected
    }

    public var kind: Kind
    /// The pool id or the proxy id.
    public var key: String
    public var title: String
    public var body: String
    public var poolID: String?
    public var proxyID: UUID?

    public init(kind: Kind, key: String, title: String, body: String, poolID: String? = nil, proxyID: UUID? = nil) {
        self.kind = kind
        self.key = key
        self.title = title
        self.body = body
        self.poolID = poolID
        self.proxyID = proxyID
    }

    public var identifier: String { Self.identifier(kind, key: key) }

    static func identifier(_ kind: Kind, key: String) -> String { "\(kind.rawValue):\(key)" }
}

/// Decides which notifications a refresh produces. Pure apart from its own
/// state: what is alerted, and since when each condition has held.
///
/// - The first evaluation is the baseline: whatever already holds counts as
///   alerted, and nothing is sent.
/// - Pool conditions are confirmed: they must hold on two evaluations whose
///   snapshots were fetched at least half a refresh interval apart, so a
///   manual refresh right after a timer refresh cannot confirm them.
/// - A low pool (two or more measured, reserve under the threshold) re-arms
///   silently at the threshold + 5 %. An exhausted pool (members, but none
///   usable or unknown) re-arms when an account is usable again, which is
///   announced only if the exhausted alert was sent.
/// - A proxy is down after two failed refreshes in a row while online, unless
///   the Mac is offline or the credential is missing; "back" follows only a
///   sent "down". Keychain carries never count as failures, so never alert.
/// - Accounts that became rejected since the previous evaluation are
///   reported in one alert per proxy, whatever their provider.
public struct AlertEngine: Sendable {
    /// Identifiers of the alerts whose condition holds or has not re-armed.
    private var alerted: Set<String> = []
    /// The part of `alerted` that was sent rather than baselined.
    private var sent: Set<String> = []
    /// The snapshot `fetchedAt` since which each condition has held.
    private var since: [String: Date] = [:]
    /// "proxy/account" of the accounts rejected at the previous evaluation.
    private var rejected: Set<String> = []
    private var baselined = false

    public init() {}

    public mutating func evaluate(_ snapshot: Snapshot, pools: [PoolSummary], threshold: Double, refreshInterval: TimeInterval,
                                  online: Bool, now: Date) -> [QuotaAlert] {
        let at = snapshot.fetchedAt
        var alerts: [QuotaAlert] = []
        for pool in pools {
            let low = QuotaAlert.identifier(.poolLow, key: pool.id), exhausted = QuotaAlert.identifier(.poolExhausted, key: pool.id)
            if let reserve = pool.reserve, reserve >= threshold + 0.05 { _ = rearm(low) }
            if fires(low, holds: pool.measured >= 2 && (pool.reserve ?? 1) < threshold, confirm: refreshInterval / 2, at: at) {
                alerts.append(QuotaAlert(kind: .poolLow, key: pool.id, title: "\(pool.title) is low", body: Self.detail(pool),
                                         poolID: pool.id))
            }
            if pool.usable > 0, rearm(exhausted) {
                alerts.append(QuotaAlert(kind: .poolAvailable, key: pool.id,
                                         title: "\(pool.title): \(Self.count(pool.usable, "account")) usable again",
                                         body: Self.detail(pool), poolID: pool.id))
            }
            if fires(exhausted, holds: pool.members >= 1 && pool.usable == 0 && pool.unknown == 0, confirm: refreshInterval / 2, at: at) {
                var body = pool.nextRecoveryAt.map { ["Until \(Self.day($0))"] } ?? []
                if pool.resetCredits > 0 { body.append(Self.count(pool.resetCredits, "reset credit")) }
                alerts.append(QuotaAlert(kind: .poolExhausted, key: pool.id, title: "\(pool.title): no usable account",
                                         body: body.joined(separator: " · "), poolID: pool.id))
            }
        }

        var rejectedNow: Set<String> = []
        for proxy in snapshot.proxies {
            let key = proxy.id.uuidString, down = QuotaAlert.identifier(.proxyDown, key: key)
            if proxy.health.isOK, rearm(down) {
                alerts.append(QuotaAlert(kind: .proxyBack, key: key, title: "\(proxy.name) is back", body: "Quota monitoring resumed.",
                                         proxyID: proxy.id))
            }
            if fires(down, holds: online && Self.isDown(proxy), at: at) {
                alerts.append(QuotaAlert(kind: .proxyDown, key: key, title: "\(proxy.name) unavailable", body: proxy.health.summary,
                                         proxyID: proxy.id))
            }
            var names: [String] = []
            for account in proxy.accounts {
                guard case .rejected = account.quota else { continue }
                let id = "\(key)/\(account.id)"
                rejectedNow.insert(id)
                if baselined, !rejected.contains(id) { names.append(account.label) }
            }
            if !names.isEmpty {
                alerts.append(QuotaAlert(kind: .accountsRejected, key: key,
                                         title: "\(Self.count(names.count, "account")) on \(proxy.name) \(names.count == 1 ? "needs" : "need") re-login",
                                         body: names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " …and \(names.count - 3) more" : ""),
                                         proxyID: proxy.id))
            }
        }
        rejected = rejectedNow
        baselined = true
        return alerts
    }

    /// Records whether condition `id` holds; true when its alert is due now:
    /// it holds, is not alerted, the baseline is past, and it has held since a
    /// snapshot fetched at least `confirm` seconds earlier.
    private mutating func fires(_ id: String, holds: Bool, confirm: TimeInterval = 0, at: Date) -> Bool {
        guard holds else {
            since[id] = nil
            return false
        }
        let first = since[id] ?? at
        since[id] = first
        guard baselined else {
            alerted.insert(id)
            return false
        }
        guard !alerted.contains(id), at.timeIntervalSince(first) >= confirm else { return false }
        alerted.insert(id)
        sent.insert(id)
        return true
    }

    /// Re-arms `id`; true when its alert had been sent.
    private mutating func rearm(_ id: String) -> Bool {
        alerted.remove(id)
        return sent.remove(id) != nil
    }

    /// Failed twice in a row for a reason of its own: not the Mac being offline, not a missing credential.
    static func isDown(_ proxy: ProxySnapshot) -> Bool {
        guard case .failed(let error) = proxy.health, proxy.consecutiveFailures >= 2 else { return false }
        switch error {
        case .offline, .missingCredential: return false
        default: return true
        }
    }

    /// "18% · 3/9 usable · next back 17 Nov · 3 reset credits"
    static func detail(_ pool: PoolSummary) -> String {
        var parts = pool.reserve.map { ["\(Int(($0 * 100).rounded()))%"] } ?? []
        parts.append("\(pool.usable)/\(pool.members) usable")
        if let back = pool.nextRecoveryAt { parts.append("next back \(day(back))") }
        if pool.resetCredits > 0 { parts.append(count(pool.resetCredits, "reset credit")) }
        return parts.joined(separator: " · ")
    }

    /// "17 Nov", in the user's time zone.
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

extension ProxySnapshot {
    /// The proxy itself has a problem worth showing: unauthorized or a login
    /// lock at once, any other failure from the second refresh in a row. The
    /// Mac being offline, a missing credential and Keychain approval are not.
    public var isUnhealthy: Bool {
        guard case .failed(let error) = health else { return false }
        switch error {
        case .offline, .missingCredential: return false
        case .unauthorized, .loginLocked: return true
        case .unreachable, .failed: return consecutiveFailures >= 2
        }
    }
}

extension ProxyHealth {
    var logLabel: String {
        switch self {
        case .ok: "ok"
        case .needsKeychainAccess: "needsKeychainAccess"
        case .failed(let error): "failed(\(error))"
        }
    }

    public var summary: String {
        switch self {
        case .ok: "Connected"
        case .needsKeychainAccess: "Motas needs your approval to read this proxy's credential from Keychain."
        case .failed(let error): error.summary
        }
    }
}

extension ProxyAccessError {
    public var summary: String {
        switch self {
        case .missingCredential: "No credential is saved for this proxy. Add it in Settings."
        case .unauthorized(let reason) where reason.isEmpty: "Credentials were rejected. Check the key or password in Settings."
        case .unauthorized(let reason): "\(reason)."
        case .loginLocked(let until): "9Router locked logins until \(until.formatted(date: .omitted, time: .shortened))."
        case .offline(let reason): "Offline: \(reason)."
        case .unreachable(let reason): "Cannot reach the proxy: \(reason)."
        case .failed(let reason): "The proxy returned an error: \(reason)."
        }
    }
}
