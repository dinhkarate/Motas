import MotasCore
import SwiftUI

public struct QuotaRing: View {
    let fraction: Double?
    let diameter: CGFloat
    let lineWidth: CGFloat
    let showsLabel: Bool
    /// Overrides both arc and track colors. Nil keeps the semantic quota tint.
    let tint: Color?

    public init(
        fraction: Double?,
        diameter: CGFloat = MotasTheme.heroRingDiameter,
        lineWidth: CGFloat = MotasTheme.heroRingWidth,
        showsLabel: Bool = true,
        tint: Color? = nil
    ) {
        self.fraction = fraction
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke((tint ?? Color.primary).opacity(0.10), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0, min(1, fraction)))
                    .stroke(
                        tint ?? MotasTheme.quotaTint(fraction),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.25), value: fraction)
            }
            if showsLabel, let fraction {
                VStack(spacing: 0) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: diameter * 0.28, weight: .semibold, design: .rounded))
                    Text("left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
