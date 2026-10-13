import Foundation

/// Reserve of one provider across every proxy.
///
/// Rules (see docs/architecture.md):
/// - an account's remaining = its tightest window;
/// - disabled accounts are excluded (the operator turned them off);
/// - accounts whose quota read failed count as 0 — an account you cannot
///   read or use is not reserve; reported windows always win over a stale
///   proxy error flag;
/// - accounts with no figures at all (`.unavailable`) are `unknown`, excluded
///   from the average and reported separately;
/// - accounts on unreachable/unauthorized proxies are not counted (the proxy
///   problem is surfaced on its own).
public struct PoolSummary: Sendable, Hashable, Identifiable {
    public var provider: Provider
    public var id: Provider { provider }
    /// Mean remaining over measured accounts; nil when none were measured.
    public var reserve: Double?
    public var measuredCount: Int
    public var exhaustedCount: Int
    public var unknownCount: Int
    /// Earliest reset among measured accounts that are below 100%.
    public var nextReset: Date?
}

public enum Pool {
    public static let exhaustedThreshold = 0.005

    public static func summarize(_ snapshot: Snapshot) -> [PoolSummary] {
        var byProvider: [Provider: [AccountSnapshot]] = [:]
        for proxy in snapshot.proxies where proxy.health.isOK {
            for account in proxy.accounts where account.state != .disabled {
                byProvider[account.provider, default: []].append(account)
            }
        }
        return byProvider.map { provider, accounts in
            var values: [Double] = []
            var unknown = 0
            var resets: [Date] = []
            for account in accounts {
                if let value = remaining(account) {
                    values.append(value)
                    if value < 1 {
                        resets += account.quota.windows.filter { $0.remainingFraction < 1 }.compactMap(\.resetsAt)
                    }
                } else {
                    unknown += 1
                }
            }
            return PoolSummary(
                provider: provider,
                reserve: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                measuredCount: values.count,
                exhaustedCount: values.filter { $0 < exhaustedThreshold }.count,
                unknownCount: unknown,
                nextReset: resets.min()
            )
        }
        .sorted { $0.provider < $1.provider }
    }

    /// nil = unknown (excluded from the average).
    public static func remaining(_ account: AccountSnapshot) -> Double? {
        switch account.quota {
        case .windows: account.quota.effectiveRemaining
        case .failed: 0
        case .unavailable: nil
        }
    }

    /// The pool shown in the menu bar: the lowest measured reserve.
    public static func headline(_ pools: [PoolSummary]) -> PoolSummary? {
        pools.filter { $0.reserve != nil }.min { $0.reserve! < $1.reserve! }
    }
}
