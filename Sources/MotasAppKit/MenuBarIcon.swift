import AppKit
import MotasCore
import SwiftUI

/// Status-bar icon: quota ring plus optional percentage, rasterized for the
/// menu bar. Monochrome template when healthy or tinting is off; semantic
/// colour when low or not ready.
@MainActor
public enum MenuBarIcon {
    public static func image(
        fraction: Double?,
        state: ReadinessState,
        showsPercentage: Bool,
        tintWhenLow: Bool
    ) -> NSImage {
        let monochrome =
            !tintWhenLow
            || ((fraction ?? 1) >= MotasTheme.cautionFraction && state == .ready)
        let color: Color =
            monochrome
            ? Color.primary
            : (fraction.map(MotasTheme.quotaTint) ?? state.tint)

        let ring = QuotaRing(fraction: fraction, diameter: 14, lineWidth: 2.5, showsLabel: false)
        let label: AnyView
        if showsPercentage, let fraction {
            label = AnyView(
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            )
        } else {
            label = AnyView(EmptyView())
        }
        let content: AnyView
        if fraction != nil {
            content = AnyView(
                HStack(spacing: 3) {
                    ring
                    label
                })
        } else {
            content = AnyView(
                HStack(spacing: 3) {
                    Image(systemName: state.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                    label
                }
            )
        }

        let tinted =
            content
            .foregroundStyle(color)
            .frame(height: 18)
        let renderer = ImageRenderer(content: tinted)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let nsImage = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        nsImage.size = NSSize(width: nsImage.size.width / renderer.scale, height: 18)
        nsImage.isTemplate = monochrome
        return nsImage
    }
}
