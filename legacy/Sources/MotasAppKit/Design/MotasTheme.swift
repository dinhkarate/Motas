import SwiftUI

public enum MotasTheme {
    public static let panelWidth: CGFloat = 340
    public static let panelPadding: CGFloat = 14
    public static let tileSpacing: CGFloat = 8
    public static let tileCornerRadius: CGFloat = 10
    public static let tileFill = Color.primary.opacity(0.055)
    public static let tileStroke = Color.primary.opacity(0.07)
    public static let heroRingDiameter: CGFloat = 72
    public static let heroRingWidth: CGFloat = 8
    public static let barHeight: CGFloat = 5
    public static let cautionFraction = 0.20
    public static let criticalFraction = 0.05

    public static func quotaTint(_ remaining: Double?) -> Color {
        guard let remaining else { return .secondary }
        if remaining < criticalFraction { return .red }
        if remaining < cautionFraction { return .orange }
        return .green
    }
}
