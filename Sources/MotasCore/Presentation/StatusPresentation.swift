import Foundation

public enum StatusPresentation {
    public static func relativeAge(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    public static func resetLabel(for date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "reset passed" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "resets in \(minutes)m" }
        let hours = Int(ceil(seconds / 3600))
        if hours < 24 { return "resets in \(hours)h" }
        let days = Int(ceil(seconds / 86_400))
        return "resets in \(days)d"
    }

    public static func qualityLabel(_ quality: DataQuality) -> String {
        switch quality {
        case .fresh: "Fresh"
        case .stale: "Stale"
        case .partial: "Partial"
        case .unavailable: "Unavailable"
        }
    }

    public static func remediation(
        health: OperationalHealth,
        quality: DataQuality
    ) -> String? {
        switch health {
        case .unauthorized:
            return "Open Settings to update monitoring credentials."
        case .unreachable:
            return "Start the local service, then refresh."
        case .unsupported:
            return "Open Settings to finish connector setup."
        case .exhausted:
            return "Use a verified fallback or wait for the quota reset."
        case .unknown:
            return "Current status could not be verified."
        case .healthy, .degraded:
            break
        }

        switch quality {
        case .stale:
            return "Refresh to update this stale status."
        case .partial:
            return "Some quota or account details are unavailable."
        case .fresh, .unavailable:
            return quality == .unavailable ? "No current data is available." : nil
        }
    }
}
