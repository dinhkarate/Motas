import SwiftUI

public struct Tile<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: MotasTheme.tileCornerRadius,
                style: .continuous
            ).fill(MotasTheme.tileFill)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: MotasTheme.tileCornerRadius,
                style: .continuous
            ).strokeBorder(MotasTheme.tileStroke)
        )
    }
}
