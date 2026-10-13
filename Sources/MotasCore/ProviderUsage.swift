import Foundation

/// Parsers for upstream provider usage payloads. Each returns `.unavailable`
/// rather than guessing when a payload carries no figures.
public enum ProviderUsage {
    public struct Parsed: Sendable, Equatable {
        public var quota: QuotaReading
        public var plan: String?
    }

    /// `GET https://chatgpt.com/backend-api/wham/usage`.
    /// Windows are labeled from `limit_window_seconds`, never assumed: a free
    /// plan has a single 30-day window, Plus has 5-hour + weekly.
    public static func codex(_ data: Data) -> Parsed {
        guard let root = JSON.object(data) else { return .init(quota: .failed("Unreadable Codex usage response"), plan: nil) }
        let plan = root.string("plan_type")
        var windows: [QuotaWindow] = []
        if let rate = root.dict("rate_limit") {
            for key in ["primary_window", "secondary_window"] {
                guard let w = rate.dict(key), let used = w.double("used_percent") else { continue }
                let seconds = w.double("limit_window_seconds")
                windows.append(QuotaWindow(
                    id: key,
                    label: seconds.map(windowLabel) ?? (key == "primary_window" ? "Primary" : "Secondary"),
                    duration: seconds,
                    remainingFraction: 1 - used / 100,
                    resetsAt: w.double("reset_at").map { Date(timeIntervalSince1970: $0) }
                ))
            }
        }
        return .init(quota: windows.isEmpty ? .unavailable("No rate-limit window reported") : .windows(windows), plan: plan)
    }

    /// `POST cloudcode-pa…/v1internal:retrieveUserQuotaSummary`
    /// (`groups[].buckets[]`) or the `fetchAvailableModels` fallback
    /// (`models{}.quotaInfo`).
    public static func antigravity(_ data: Data) -> Parsed {
        guard let root = JSON.object(data) else { return .init(quota: .failed("Unreadable Antigravity quota response"), plan: nil) }
        var windows: [QuotaWindow] = []
        for group in root.dicts("groups") {
            let groupName = group.string("displayName") ?? "Models"
            for bucket in group.dicts("buckets") where bucket.bool("disabled") != true {
                guard let remaining = bucket.double("remainingFraction") else { continue }
                let window = bucket.string("window")
                windows.append(QuotaWindow(
                    id: bucket.string("bucketId") ?? "\(groupName)-\(window ?? "")",
                    label: window.map { "\(groupName) · \($0.capitalized)" } ?? groupName,
                    duration: window == "weekly" ? 604_800 : (window == "daily" ? 86_400 : nil),
                    remainingFraction: remaining,
                    resetsAt: Dates.iso(bucket.string("resetTime"))
                ))
            }
        }
        if windows.isEmpty, let models = root.dict("models") {
            for (id, value) in models.sorted(by: { $0.key < $1.key }) {
                guard let model = value as? [String: Any], let info = model.dict("quotaInfo"),
                      let remaining = info.double("remainingFraction") else { continue }
                windows.append(QuotaWindow(
                    id: id,
                    label: model.string("displayName") ?? id,
                    remainingFraction: remaining,
                    resetsAt: Dates.iso(info.string("resetTime"))
                ))
            }
        }
        return .init(quota: windows.isEmpty ? .unavailable("No quota buckets reported") : .windows(windows), plan: nil)
    }

    /// `GET https://api.anthropic.com/api/oauth/usage`.
    /// Shape from CodexBar / CLIProxyAPI Management Center source; not yet
    /// verified against a live account.
    public static func claude(_ data: Data) -> Parsed {
        guard let root = JSON.object(data) else { return .init(quota: .failed("Unreadable Claude usage response"), plan: nil) }
        let keys: [(String, String, TimeInterval)] = [
            ("five_hour", "5-hour", 18_000),
            ("seven_day", "Weekly", 604_800),
            ("seven_day_opus", "Weekly · Opus", 604_800),
            ("seven_day_sonnet", "Weekly · Sonnet", 604_800),
        ]
        let windows = keys.compactMap { key, label, duration -> QuotaWindow? in
            guard let w = root.dict(key), let utilization = w.double("utilization") else { return nil }
            return QuotaWindow(id: key, label: label, duration: duration,
                               remainingFraction: 1 - utilization / 100,
                               resetsAt: Dates.iso(w.string("resets_at")))
        }
        return .init(quota: windows.isEmpty ? .unavailable("No usage window reported") : .windows(windows), plan: nil)
    }

    /// 9Router `GET /api/usage/{connectionId}`:
    /// `{plan, quotas: {name: {used, total, remaining?, remainingPercentage?, resetAt, unlimited}}}`
    /// or `{plan, message}` when the provider gave no figures.
    public static func nineRouter(_ data: Data) -> Parsed {
        guard let root = JSON.object(data) else { return .init(quota: .failed("Unreadable 9Router usage response"), plan: nil) }
        let plan = root.string("plan")
        guard let quotas = root.dict("quotas"), !quotas.isEmpty else {
            return .init(quota: .unavailable(root.string("message") ?? root.string("error") ?? "No quota reported"), plan: plan)
        }
        var windows: [QuotaWindow] = []
        for (name, value) in quotas.sorted(by: { $0.key < $1.key }) {
            guard let q = value as? [String: Any] else { continue }
            let label = name.prefix(1).uppercased() + name.dropFirst()
            if q.bool("unlimited") == true {
                windows.append(QuotaWindow(id: name, label: "\(label) (unlimited)", remainingFraction: 1))
                continue
            }
            let remaining: Double
            if let pct = q.double("remainingPercentage") {
                remaining = pct / 100
            } else if let total = q.double("total"), total > 0, let used = q.double("used") {
                remaining = (total - used) / total
            } else {
                continue
            }
            windows.append(QuotaWindow(id: name, label: label, remainingFraction: remaining,
                                       resetsAt: Dates.iso(q.string("resetAt"))))
        }
        return .init(quota: windows.isEmpty ? .unavailable("No quota reported") : .windows(windows), plan: plan)
    }

    static func windowLabel(_ seconds: Double) -> String {
        switch Int(seconds) {
        case 18_000: return "5-hour"
        case 86_400: return "Daily"
        case 604_800: return "Weekly"
        case 2_592_000: return "30-day"
        case let s where s % 86_400 == 0: return "\(s / 86_400)-day"
        case let s where s % 3_600 == 0: return "\(s / 3_600)-hour"
        case let s: return "\(s / 60)-minute"
        }
    }
}
