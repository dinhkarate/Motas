import MotasCore
import SwiftUI

/// Shared look for the panel, menu bar and widget. Values follow what the
/// established quota apps converged on (CodexBar, Quotio, Claude-Usage-Tracker):
/// thin capsule bars, provider brand colors, red/orange only when low,
/// monospaced digits everywhere.
public enum Design {
    public static let locale = Locale(identifier: "en_US")
    public static let criticalFraction = 0.10

    public static func color(for provider: Provider) -> Color {
        switch provider.rawValue {
        case "codex": Color(hex: 0x49A3B0)
        case "claude": Color(hex: 0xCC7C5E)
        case "antigravity": Color(hex: 0x60BA7E)
        case "gemini-cli", "gemini": Color(hex: 0xAB87EA)
        default:
            // Stable hue per unknown provider id.
            Color(hue: Double(provider.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360,
                  saturation: 0.45, brightness: 0.75)
        }
    }

    /// Provider color while healthy; orange under the user's threshold, red when critical.
    public static func fill(_ fraction: Double?, provider: Provider, threshold: Double) -> Color {
        guard let fraction else { return .secondary }
        if fraction <= criticalFraction { return .red }
        if fraction < threshold { return .orange }
        return color(for: provider)
    }

    /// Text color for a percentage: neutral when healthy, warning colors when low.
    public static func text(_ fraction: Double?, threshold: Double) -> Color {
        guard let fraction else { return .secondary }
        if fraction <= criticalFraction { return .red }
        if fraction < threshold { return .orange }
        return .primary
    }

    public static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    public static func relative(_ date: Date, now: Date = .now) -> String {
        if abs(date.timeIntervalSince(now)) < 45 { return date > now ? "in a moment" : "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    public static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    public static func monogram(_ provider: Provider) -> String {
        switch provider.rawValue {
        case "codex": "Cx"
        case "claude": "Cl"
        case "antigravity": "Ag"
        case "gemini-cli": "Gm"
        default: String(provider.displayName.prefix(2))
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Capsule progress bar showing what is LEFT. A non-zero value never renders
/// thinner than the bar is tall, so 2% is still visible.
public struct CapsuleBar: View {
    let fraction: Double?
    let color: Color
    let height: CGFloat

    public init(_ fraction: Double?, color: Color, height: CGFloat = 6) {
        self.fraction = fraction
        self.color = color
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let fraction, fraction > 0 {
                    Capsule().fill(color)
                        .frame(width: max(height, geo.size.width * min(fraction, 1)))
                }
            }
        }
        .frame(height: height)
    }
}

/// Two-letter provider badge in the provider's color.
public struct ProviderBadge: View {
    let provider: Provider
    let size: CGFloat

    public init(_ provider: Provider, size: CGFloat = 20) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        Text(Design.monogram(provider))
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Design.color(for: provider)))
    }
}
