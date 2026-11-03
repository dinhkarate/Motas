import Foundation

/// Canonical window groups: their ids, labels and display order. Periods
/// ("primary", "5h", "weekly"…) are lane ids, labelled by `periodLabel`.
public enum QuotaGroups {
    /// Known groups in display order; others follow alphabetically.
    public static let order = ["gemini", "claude-gpt", "pro", "flash", "flash-lite", "review", "spark", "image", "other"]

    public static func precedes(_ a: String, _ b: String) -> Bool {
        let ia = order.firstIndex(of: a) ?? order.count, ib = order.firstIndex(of: b) ?? order.count
        return ia != ib ? ia < ib : a < b
    }

    public static func label(provider: Provider, group: String) -> String {
        switch (provider.rawValue, group) {
        case ("codex", "review"): "Code review"
        case ("codex", "spark"): "Spark"
        case ("antigravity", "gemini"): "Gemini"
        case ("antigravity", "claude-gpt"): "Claude & GPT"
        case ("antigravity", "image"): "Image"
        case ("antigravity", "other"): "Other"
        case ("gemini-cli", "pro"): "Pro"
        case ("gemini-cli", "flash"): "Flash"
        case ("gemini-cli", "flash-lite"): "Flash-Lite"
        default: capitalised(group)
        }
    }

    /// From the reported duration when there is one, else from the period id.
    /// Never from the distance to the reset: a 9Router Codex window stays "Primary".
    public static func periodLabel(_ period: String, duration: TimeInterval?) -> String {
        if let duration {
            switch Int(duration) {
            case 18_000: return "5-hour"
            case 86_400: return "Daily"
            case 604_800: return "Weekly"
            case 2_592_000: return "30-day"
            case let s where s > 0 && s % 86_400 == 0: return "\(s / 86_400)-day"
            case let s where s > 0 && s % 3_600 == 0: return "\(s / 3_600)-hour"
            default: break
            }
        }
        switch period {
        case "primary": return "Primary"
        case "secondary": return "Secondary"
        case "5h": return "5-hour"
        case "weekly": return "Weekly"
        case "daily": return "Daily"
        default: return capitalised(period)
        }
    }

    /// "<Group> · <Period>" or "<Period>" for windows with a period; per-model
    /// windows (no period) use the proxy's display name, else the key.
    static func windowLabel(provider: Provider, key: String, group: String?, period: String?,
                            duration: TimeInterval?, displayName: String?) -> String {
        guard let period else { return displayName ?? key }
        let periodLabel = periodLabel(period, duration: duration)
        return group.map { "\(label(provider: provider, group: $0)) · \(periodLabel)" } ?? periodLabel
    }

    private static func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
