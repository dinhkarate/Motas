import MotasCore
import SwiftUI

public struct QuotaBar: View {
    let window: QuotaWindow
    let now: Date

    public init(window: QuotaWindow, now: Date = Date()) {
        self.window = window
        self.now = now
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(window.name)
                .font(.caption)
                .frame(width: 74, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: MotasTheme.barHeight)
                    .overlay(alignment: .leading) {
                        if let fraction = window.remainingFraction {
                            Capsule()
                                .fill(MotasTheme.quotaTint(fraction))
                                .frame(
                                    width: geometry.size.width
                                        * max(0, min(1, fraction)),
                                    height: MotasTheme.barHeight
                                )
                        }
                    }
                    .frame(maxHeight: .infinity)
            }
            .frame(height: MotasTheme.barHeight)
            if let fraction = window.remainingFraction {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            } else {
                Text("—")
                    .font(.caption)
                    .frame(width: 36, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
        if let reset = StatusPresentation.resetLabel(for: window.resetsAt, now: now) {
            Text(reset)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
