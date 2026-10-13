import Foundation

public enum QuotaAggregation {
    /// Lowercases and replaces every run of non-alphanumeric characters with
    /// a single "-", trimming leading and trailing separators. Empty input
    /// yields "quota". Both proxy connectors use this for QuotaWindow ids.
    public static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var result = ""
        var pendingSeparator = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator, !result.isEmpty {
                    result.append("-")
                }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else if !result.isEmpty {
                pendingSeparator = true
            }
        }
        return result.isEmpty ? "quota" : result
    }

    /// Route-level view of a rotating account pool: for each distinct window
    /// `name`, keep the account bucket with the HIGHEST remainingFraction,
    /// because a router can still serve traffic through the best account.
    /// Result is sorted by window name ascending for snapshot determinism.
    public static func routeWindows(
        from accounts: [ProxyAccountStatus],
        idPrefix: String
    ) -> [QuotaWindow] {
        var best: [String: QuotaWindow] = [:]
        for account in accounts {
            for window in account.quotaWindows {
                guard let fraction = window.remainingFraction else { continue }
                if let existing = best[window.name],
                    (existing.remainingFraction ?? 0) >= fraction
                {
                    continue
                }
                best[window.name] = QuotaWindow(
                    id: "\(idPrefix)/route/\(slug(window.name))",
                    name: window.name,
                    unit: .percentage,
                    remainingFraction: fraction,
                    resetsAt: window.resetsAt,
                    isEnforced: true
                )
            }
        }
        return best.values.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
    }

    /// .exhausted when every account is exhausted, .healthy when at least one
    /// is healthy, .degraded otherwise, .unknown when the list is empty.
    public static func poolHealth(_ accounts: [ProxyAccountStatus]) -> OperationalHealth {
        guard !accounts.isEmpty else { return .unknown }
        if accounts.allSatisfy({ $0.health == .exhausted }) { return .exhausted }
        if accounts.contains(where: { $0.health == .healthy }) { return .healthy }
        return .degraded
    }
}
