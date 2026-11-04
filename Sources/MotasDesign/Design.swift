import AppKit
import MotasCore
import SwiftUI

/// Shared look for the panel, menu bar and widgets. One colour rule —
/// `Design.level` — for every surface; provider accents only mark a family.
public enum Design {
    /// `en_GB` gives the spec's "17 Nov", "14:05" and "2 min ago".
    public static let locale = Locale(identifier: "en_GB")

    /// At or below this, a pool is critical whatever the threshold.
    public static let criticalFraction = 0.005

    public enum Level: Sendable, Equatable {
        case good
        case low
        case critical

        /// Dark values are the design table's pastels; light values are the
        /// darker equivalents that keep the same meaning readable on white.
        public var color: Color {
            switch self {
            case .good: Design.adaptive(light: 0x12864a, dark: 0x55d98a)
            case .low: Design.adaptive(light: 0xa86400, dark: 0xf0b35b)
            case .critical: Design.adaptive(light: 0xc02b46, dark: 0xfb7185)
            }
        }
    }

    /// Critical: at or below 0.5 %, or below half the threshold. Low: below
    /// the threshold. Good: otherwise.
    public static func level(_ fraction: Double, threshold: Double) -> Level {
        if fraction <= criticalFraction || fraction < threshold / 2 { return .critical }
        if fraction < threshold { return .low }
        return .good
    }

    /// The meter/number colour; nil (unknown) stays neutral.
    public static func levelColor(_ fraction: Double?, threshold: Double) -> Color {
        guard let fraction else { return .secondary }
        return level(fraction, threshold: threshold).color
    }

    /// One decimal, with ".0" dropped: 51.3%, 51%.
    public static func percent(_ fraction: Double) -> String {
        let value = (fraction * 1000).rounded() / 10
        return value == value.rounded() ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }

    /// The menu bar's whole percent.
    public static func percentWhole(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// The family mark and accent. A mark is one glyph; an unknown provider
    /// gets its first letter.
    public static func mark(for provider: Provider) -> String {
        switch provider.rawValue {
        case "codex": "O"
        case "antigravity", "gemini-cli", "gemini": "✦"
        case "claude": "A"
        case "xai": "𝕏"
        default: String(provider.displayName.prefix(1)).uppercased()
        }
    }

    public static func accent(for provider: Provider) -> Color {
        switch provider.rawValue {
        case "codex": adaptive(light: 0x3f4652, dark: 0xd9dde5)
        case "antigravity", "gemini-cli", "gemini": adaptive(light: 0x2f6fed, dark: 0x7ba7ff)
        case "claude": adaptive(light: 0xb5502f, dark: 0xe58a68)
        case "xai": adaptive(light: 0x374151, dark: 0xf2f4f8)
        default: adaptive(light: 0x4b5563, dark: 0xc7ccd6)
        }
    }

    /// The family a pool wears. Antigravity's Claude & GPT lane belongs to the
    /// Claude family, not to the Gemini star.
    public static func family(for poolID: String) -> Provider? {
        let parts = poolID.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let provider = Provider(rawValue: String(parts[0]))
        return provider == .antigravity && parts[2] == "claude-gpt" ? .claude : provider
    }

    /// A colour that follows the effective appearance, so one token works on
    /// the dark desktop widget and on the light panel alike.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    public static func relative(_ date: Date, now: Date = .now) -> String {
        if abs(date.timeIntervalSince(now)) < 45 { return date > now ? "in a moment" : "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "17 Nov", in the user's time zone.
    public static func day(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "14:05", in the user's time zone.
    public static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    public static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension PoolSummary {
    /// The family mark and accent for this pool's title and cards.
    public var familyProvider: Provider { Design.family(for: id) ?? key.provider }
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

/// The family mark in a small tinted tile: a glyph, never a two-letter badge.
public struct ProviderBadge: View {
    let provider: Provider
    let size: CGFloat

    public init(_ provider: Provider, size: CGFloat = 20) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        let accent = Design.accent(for: provider)
        Text(Design.mark(for: provider))
            .font(.system(size: size * 0.52, weight: .bold, design: .serif))
            .foregroundStyle(accent)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(accent.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(accent.opacity(0.34), lineWidth: 1))
    }
}
