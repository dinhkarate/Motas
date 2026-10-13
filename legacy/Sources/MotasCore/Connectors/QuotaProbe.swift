import Foundation

/// What caused a connector refresh.
public enum RefreshTrigger: Sendable, Equatable {
    /// Timer-driven automatic refresh.
    case scheduled
    /// Explicit user action: Refresh button, settings save, connection test.
    case manual
}

/// Cooldown/cache policy for proxy quota probes.
public struct QuotaProbePolicy: Sendable, Equatable {
    public var isEnabled: Bool
    public var interval: TimeInterval
    public var manualFloor: TimeInterval
    public var cacheMaximumAge: TimeInterval

    public init(
        isEnabled: Bool = true,
        interval: TimeInterval = 600,
        manualFloor: TimeInterval = 60,
        cacheMaximumAge: TimeInterval = 3600
    ) {
        self.isEnabled = isEnabled
        self.interval = interval
        self.manualFloor = manualFloor
        self.cacheMaximumAge = cacheMaximumAge
    }
}

private struct QuotaProbeEntry: Sendable {
    var lastAttempt: Date?
    var unsupported: Bool = false
    var windows: [QuotaWindow]?
    var storedAt: Date?
}

/// Cooldown gate and short-lived window cache for proxy quota probes.
///
/// One cache is shared across connectors; entries are keyed per account
/// (e.g. `"cliproxyapi/<authIndex>"`). `markUnsupported` is permanent for the
/// process lifetime and is used for HTTP 501/404 from a quota endpoint.
public actor QuotaProbeCache {
    private var policy: QuotaProbePolicy
    private var entries: [String: QuotaProbeEntry] = [:]

    public init(policy: QuotaProbePolicy = .init()) {
        self.policy = policy
    }

    public func setPolicy(_ policy: QuotaProbePolicy) {
        self.policy = policy
    }

    /// False when probing is disabled, the key is cooling down, or the key
    /// was previously marked unsupported.
    public func shouldProbe(key: String, trigger: RefreshTrigger, now: Date) -> Bool {
        guard policy.isEnabled else { return false }
        guard let entry = entries[key] else { return true }
        guard !entry.unsupported else { return false }
        guard let lastAttempt = entry.lastAttempt else { return true }
        let floor: TimeInterval =
            trigger == .manual ? policy.manualFloor : policy.interval
        return now.timeIntervalSince(lastAttempt) >= floor
    }

    public func store(_ windows: [QuotaWindow], key: String, now: Date) {
        entries[key] = QuotaProbeEntry(
            lastAttempt: now,
            unsupported: false,
            windows: windows,
            storedAt: now
        )
    }

    public func markUnsupported(key: String) {
        var entry = entries[key] ?? QuotaProbeEntry()
        entry.unsupported = true
        entries[key] = entry
    }

    public func markFailure(key: String, now: Date) {
        var entry = entries[key] ?? QuotaProbeEntry()
        entry.lastAttempt = now
        entries[key] = entry
    }

    /// Windows from the last successful probe if newer than `cacheMaximumAge`.
    public func cached(key: String, now: Date) -> [QuotaWindow]? {
        guard let entry = entries[key],
            let windows = entry.windows,
            let storedAt = entry.storedAt
        else { return nil }
        guard now.timeIntervalSince(storedAt) <= policy.cacheMaximumAge else { return nil }
        return windows
    }
}
