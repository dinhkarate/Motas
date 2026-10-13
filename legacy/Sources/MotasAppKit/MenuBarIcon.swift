import AppKit
import MotasCore
import SwiftUI

/// Status-bar icon: quota ring plus optional percentage, rasterized for the
/// menu bar. Monochrome template when healthy or tinting is off; semantic
/// colour when low or not ready.
@MainActor
public enum MenuBarIcon {
    /// Pure-SwiftUI status-bar label. MUST be used for the live
    /// `MenuBarExtra` label: rasterizing with `ImageRenderer` inside the
    /// label closure runs in the AttributeGraph evaluation context (no
    /// subgraph) and crashes with `External<()>`.
    public struct Label: View {
        let fraction: Double?
        let state: ReadinessState
        let showsPercentage: Bool
        let tintWhenLow: Bool

        public init(
            fraction: Double?,
            state: ReadinessState,
            showsPercentage: Bool,
            tintWhenLow: Bool
        ) {
            self.fraction = fraction
            self.state = state
            self.showsPercentage = showsPercentage
            self.tintWhenLow = tintWhenLow
        }

        public var body: some View {
            HStack(spacing: 3) {
                if fraction != nil {
                    QuotaRing(fraction: fraction, diameter: 14, lineWidth: 2.5, showsLabel: false)
                } else {
                    Image(systemName: state.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                }
                if showsPercentage, let fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(MenuBarIcon.color(
                fraction: fraction, state: state, tintWhenLow: tintWhenLow))
            .frame(height: 18)
        }
    }

    static func color(
        fraction: Double?,
        state: ReadinessState,
        tintWhenLow: Bool
    ) -> Color {
        let monochrome =
            !tintWhenLow
            || ((fraction ?? 1) >= MotasTheme.cautionFraction && state == .ready)
        return monochrome ? Color.primary : (fraction.map(MotasTheme.quotaTint) ?? state.tint)
    }

    public static func image(
        fraction: Double?,
        state: ReadinessState,
        showsPercentage: Bool,
        tintWhenLow: Bool
    ) -> NSImage {
        let tinted = Label(
            fraction: fraction,
            state: state,
            showsPercentage: showsPercentage,
            tintWhenLow: tintWhenLow
        )
        let renderer = ImageRenderer(content: tinted)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let nsImage = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        nsImage.size = NSSize(width: nsImage.size.width / renderer.scale, height: 18)
        nsImage.isTemplate = !tintWhenLow
            || ((fraction ?? 1) >= MotasTheme.cautionFraction && state == .ready)
        return nsImage
    }
}
