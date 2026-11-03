import Foundation

/// Pure parsers for usage bodies. They never guess: no figures means
/// `.unavailable` (by design) or `.failed` (this read), never 0 or 100 %.
public enum ProviderUsage {
    /// When an account without figures by design is asked again.
    static let unmeteredRecheck: TimeInterval = 6 * 3600

    /// A 9Router `GET /api/usage/{id}` 200 body. The first step that applies
    /// wins: unreadable → transient; a message, even beside `quotas` →
    /// `classify`; usable quotas → windows; quotas that all have
    /// `total == 0` → unavailable; anything else → transient.
    public static func nineRouter(_ data: Data, provider: Provider) -> UsageReading {
        guard let root = JSON.object(data) else { return .failed(.transient("Unreadable usage response")) }
        let extras = UsageExtras(resetCredits: root.dict("resetCredits")?.int("availableCount"),
                                 quotaExceeded: root.bool("isQuotaExceeded") == true ? true : nil)
        if let message = root.string("message")?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return classify(message, extras: extras)
        }
        let quotas = root.dict("quotas") ?? [:]
        var entries: [Entry] = []
        var zeroTotals = 0
        for (key, value) in quotas.sorted(by: { $0.key < $1.key }) {
            guard let q = value as? [String: Any] else { continue }
            let total = q.double("total") ?? 0
            let fraction: Double
            if q.bool("unlimited") == true {
                fraction = 1
            } else if let percentage = q.double("remainingPercentage") {
                fraction = percentage / 100
            } else if total > 0, let used = q.double("used") {
                fraction = (total - used) / total
            } else if total > 0, let remaining = q.double("remaining") {
                fraction = remaining / total
            } else {
                if q.double("total") == 0 { zeroTotals += 1 }
                continue
            }
            entries.append(Entry(key: key, displayName: q.string("displayName"), fraction: fraction,
                                 resetsAt: Dates.iso(q.string("resetAt")), unlimited: q.bool("unlimited") == true))
        }
        if !entries.isEmpty {
            let plan = provider == .antigravity ? antigravityPlan(root) : normalisedPlan(root.string("plan"))
            return .windows(nineRouterWindows(entries, provider: provider), plan: plan, extras: extras)
        }
        if !quotas.isEmpty, zeroTotals == quotas.count {
            let message = extras.quotaExceeded == true ? "No figures (Qoder reports quota exceeded)" : "No figures reported"
            return .unavailable(message, recheckAfter: unmeteredRecheck, extras: extras)
        }
        return .failed(.transient("No quota figures in this read"))
    }

    /// Classifies a 9Router handler message. Case-insensitive; the first matching row wins.
    static func classify(_ message: String, extras: UsageExtras) -> UsageReading {
        let text = message.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        if has("chat may still work") { return .failed(.transient(message)) }
        if let match = text.firstMatch(of: /\((\d{3})\)|returned (\d{3})|error: (\d{3})/),
           let status = Int(match.1 ?? match.2 ?? match.3 ?? "") {
            switch status {
            case 429: return .failed(.rateLimited(until: nil, message))
            case 401: return .failed(.credentialRejected(message))
            default: return .failed(.transient(message))
            }
        }
        if has("not implemented", "usage not available for this connection", "tracked per request",
               "no usage limits reported", "no credit allocation", "requires admin", "require admin") {
            return .unavailable(message, recheckAfter: unmeteredRecheck, extras: extras)
        }
        if has("invalid or expired", "re-authorize", "reconnect", "token not available", "no access token", "api key not available") {
            return .failed(.credentialRejected(message))
        }
        if has("rate limit", "too many requests") { return .failed(.rateLimited(until: nil, message)) }
        return .failed(.transient(message))
    }

    /// One usable 9Router `quotas` entry.
    struct Entry {
        var key: String
        var displayName: String?
        var fraction: Double
        var resetsAt: Date?
        var unlimited: Bool
    }

    /// 9Router's Antigravity family buckets.
    static let antigravityBuckets: [String: (group: String, period: String)] = [
        "gemini_session": ("gemini", "5h"), "gemini_weekly": ("gemini", "weekly"),
        "claude_gpt_session": ("claude-gpt", "5h"), "claude_gpt_weekly": ("claude-gpt", "weekly"),
    ]

    static func nineRouterWindows(_ entries: [Entry], provider: Provider) -> [QuotaWindow] {
        let limited = Set(entries.compactMap { antigravityBuckets[$0.key]?.group })
        return entries.map { entry in
            let group: String?, period: String?, role: WindowRole
            if provider != .antigravity {
                (group, period) = nineRouterKey(entry.key, provider: provider)
                role = .limit
            } else if let bucket = antigravityBuckets[entry.key] {
                (group, period, role) = (bucket.group, bucket.period, .limit)
            } else {
                (group, role) = antigravityModel(entry.key, limited: limited)
                period = nil
            }
            var w = window(entry.key, provider: provider, fraction: entry.fraction, resetsAt: entry.resetsAt,
                           group: group, period: period, role: role, displayName: entry.displayName)
            if entry.unlimited { w.label += " (unlimited)" }
            return w
        }
    }

    /// Group and period of a 9Router quota key; an unknown key is its own period.
    static func nineRouterKey(_ key: String, provider: Provider) -> (group: String?, period: String?) {
        switch provider {
        case .codex:
            let periods = ["session": "primary", "weekly": "secondary"]
            if let period = periods[key] { return (nil, period) }
            for group in ["review", "spark"] where key.hasPrefix(group + "_") {
                if let period = periods[String(key.dropFirst(group.count + 1))] { return (group, period) }
            }
        case .claude:
            if key == "session (5h)" { return (nil, "5h") }
            if key == "weekly (7d)" { return (nil, "weekly") }
            if let model = key.wholeMatch(of: /weekly (.+) \(7d\)/)?.1 {
                return (model.lowercased().replacingOccurrences(of: " ", with: "-"), "weekly")
            }
        case .geminiCLI:
            return (key.contains("lite") ? "flash-lite" : key.contains("flash") ? "flash" : key.contains("pro") ? "pro" : key, nil)
        default:
            break
        }
        return (nil, key)
    }

    /// A per-model Antigravity key. Image models and unknown keys are details;
    /// a text model counts for its family (`.model`) only when the same
    /// reading has no bucket (`.limit`) for that family.
    static func antigravityModel(_ key: String, limited: Set<String>) -> (group: String, role: WindowRole) {
        let group = key.contains("image") ? "image"
            : key.hasPrefix("gemini-") ? "gemini"
            : key.hasPrefix("claude-") || key.hasPrefix("gpt-") ? "claude-gpt"
            : "other"
        let isText = group == "gemini" || group == "claude-gpt"
        return (group, isText && !limited.contains(group) ? .model : .detail)
    }

    static func window(_ key: String, provider: Provider, fraction: Double, resetsAt: Date?, duration: TimeInterval? = nil,
                       group: String?, period: String?, role: WindowRole, displayName: String? = nil) -> QuotaWindow {
        QuotaWindow(id: key,
                    label: QuotaGroups.windowLabel(provider: provider, key: key, group: group, period: period,
                                                   duration: duration, displayName: displayName),
                    duration: duration, remainingFraction: fraction, resetsAt: resetsAt, group: group, period: period, role: role)
    }

    /// Every plan string, usage and metadata alike: trimmed; "" and "unknown" mean none.
    static func normalisedPlan(_ plan: String?) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty,
              plan.lowercased() != "unknown" else { return nil }
        return plan
    }

    /// 9Router's Antigravity `plan` is "Antigravity" for every account; the
    /// tier is `subscriptionInfo.paidTier.name`: "Google AI Plus" → "AI Plus",
    /// "Antigravity Starter Quota" → "Starter".
    static func antigravityPlan(_ root: [String: Any]) -> String? {
        let plan = root.string("plan")
        let paid = root.dict("subscriptionInfo")?.dict("paidTier")?.string("name")
        guard var name = normalisedPlan(paid ?? (plan == "Antigravity" ? nil : plan)) else { return nil }
        for prefix in ["Google ", "Antigravity "] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        if name.hasSuffix(" Quota") { name.removeLast(" Quota".count) }
        return normalisedPlan(name)
    }

    // MARK: CLIProxyAPI (upstream bodies from /api-call)

    /// `GET chatgpt.com/backend-api/wham/usage`. Windows keep the reported
    /// `limit_window_seconds` as their duration: a free plan has a single
    /// 30-day window, Plus has 5-hour + weekly.
    public static func codex(_ data: Data, now: Date) -> UsageReading {
        guard let root = JSON.object(data) else { return .failed(.transient("Unreadable usage response")) }
        var windows = codexWindows(root.dict("rate_limit"), group: nil, now: now)
        windows += codexWindows(root.dict("code_review_rate_limit"), group: "review", now: now)
        for limit in root.dicts("additional_rate_limits")
        where "\(limit.string("limit_name") ?? "") \(limit.string("metered_feature") ?? "")".lowercased().contains("spark") {
            windows += codexWindows(limit.dict("rate_limit"), group: "spark", now: now)
        }
        guard !windows.isEmpty else { return .failed(.transient("No quota figures in this read")) }
        let credits = root.dict("rate_limit_reset_credits")
        return .windows(windows, plan: normalisedPlan(root.string("plan_type")),
                        extras: UsageExtras(resetCredits: credits?.int("applicable_available_count") ?? credits?.int("available_count")))
    }

    static func codexWindows(_ limit: [String: Any]?, group: String?, now: Date) -> [QuotaWindow] {
        [("primary_window", "primary"), ("secondary_window", "secondary")].compactMap { key, period in
            guard let w = limit?.dict(key), let used = w.double("used_percent") else { return nil }
            let resetsAt = w.double("reset_at").map { Date(timeIntervalSince1970: $0) }
                ?? w.double("reset_after_seconds").map { now.addingTimeInterval($0) }
            return window(group.map { "\($0)_\(key)" } ?? key, provider: .codex, fraction: 1 - used / 100, resetsAt: resetsAt,
                          duration: w.double("limit_window_seconds"), group: group, period: period, role: .limit)
        }
    }

    /// `retrieveUserQuotaSummary` (`groups[].buckets[]`) and the
    /// `fetchAvailableModels` shape (`models{}.quotaInfo`).
    public static func antigravity(_ data: Data) -> UsageReading {
        guard let root = JSON.object(data) else { return .failed(.transient("Unreadable usage response")) }
        var windows: [QuotaWindow] = []
        for group in root.dicts("groups") {
            let name = group.string("displayName") ?? ""
            let id = name.contains("Gemini") ? "gemini" : name.contains("Claude") || name.contains("GPT") ? "claude-gpt" : "other"
            for bucket in group.dicts("buckets") where bucket.bool("disabled") != true {
                guard let remaining = bucket.double("remainingFraction") else { continue }
                let period = bucket.string("window").map(summaryPeriod)
                windows.append(window(bucket.string("bucketId") ?? "\(id)-\(period ?? "")", provider: .antigravity,
                                      fraction: remaining, resetsAt: Dates.iso(bucket.string("resetTime")), group: id,
                                      period: period, role: id == "other" ? .detail : .limit, displayName: bucket.string("displayName")))
            }
        }
        let limited = Set(windows.filter { $0.role == .limit }.compactMap(\.group))
        for (key, value) in (root.dict("models") ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let model = value as? [String: Any], model.bool("isInternal") != true,
                  let info = model.dict("quotaInfo"), let remaining = info.double("remainingFraction") else { continue }
            let (group, role) = antigravityModel(key, limited: limited)
            windows.append(window(key, provider: .antigravity, fraction: remaining, resetsAt: Dates.iso(info.string("resetTime")),
                                  group: group, period: nil, role: role, displayName: model.string("displayName")))
        }
        guard !windows.isEmpty else { return .failed(.transient("No quota figures in this read")) }
        return .windows(windows, plan: nil, extras: UsageExtras())
    }

    /// Bucket `window` → period: weekly; 5h, session or hourly → 5h; daily; anything else as is.
    static func summaryPeriod(_ window: String) -> String {
        switch window.lowercased() {
        case "weekly": "weekly"
        case "5h", "session", "hourly": "5h"
        case "daily": "daily"
        default: window
        }
    }

    /// `GET api.anthropic.com/api/oauth/usage`: `five_hour`, `seven_day` and
    /// `seven_day_<model>` utilisation. Shape from CodexBar / CLIProxyAPI
    /// Management Center source; not yet verified against a live account.
    public static func claude(_ data: Data) -> UsageReading {
        guard let root = JSON.object(data) else { return .failed(.transient("Unreadable usage response")) }
        let windows = root.keys.sorted().compactMap { key -> QuotaWindow? in
            let group: String?, period: String
            switch key {
            case "five_hour": (group, period) = (nil, "5h")
            case "seven_day": (group, period) = (nil, "weekly")
            case _ where key.hasPrefix("seven_day_"): (group, period) = (String(key.dropFirst("seven_day_".count)), "weekly")
            default: return nil
            }
            guard let w = root.dict(key), let utilization = w.double("utilization") else { return nil }
            return window(key, provider: .claude, fraction: 1 - utilization / 100, resetsAt: Dates.iso(w.string("resets_at")),
                          group: group, period: period, role: .limit)
        }
        guard !windows.isEmpty else { return .failed(.transient("No quota figures in this read")) }
        return .windows(windows, plan: nil, extras: UsageExtras())
    }
}
