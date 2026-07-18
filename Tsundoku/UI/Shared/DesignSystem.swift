import SwiftUI

/// Central visual constants so cards, floating chrome, and reader panels share
/// one surface language. Values match the shipped design; adjust here rather
/// than at call sites.
enum DesignTokens {
    static let cardCornerRadius: CGFloat = 12
    static let panelCornerRadius: CGFloat = 16
    static let dockCornerRadius: CGFloat = 22
    static let readerPanelCornerRadius: CGFloat = 18

    static let hairlineOpacity: Double = 0.08
    static let cardShadowOpacity: Double = 0.12
    static let cardShadowRadius: CGFloat = 3
    static let cardShadowYOffset: CGFloat = 2
    static let floatingShadowOpacity: Double = 0.16
    static let floatingShadowRadius: CGFloat = 12
    static let floatingShadowYOffset: CGFloat = 5

    /// Reader chrome stays opaque near-black so it remains legible over any
    /// page artwork; materials would sample bright pages behind the panel.
    static let readerPanelFillOpacity: Double = 0.82
    static let readerHairlineOpacity: Double = 0.16
    static let readerShadowOpacity: Double = 0.24
}

extension View {
    /// Rounded display typography for section headers and titles only; body
    /// text keeps the default design.
    func displayHeader() -> some View {
        font(.title2.bold()).fontDesign(.rounded)
    }

    /// In-scroll card surface: material plus hairline, no shadow. Floating
    /// chrome (toast, dock) adds the shadow via floatingSurface.
    func cardSurface(cornerRadius: CGFloat = DesignTokens.panelCornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.regularMaterial, in: shape)
            .overlay { shape.stroke(Color.primary.opacity(DesignTokens.hairlineOpacity), lineWidth: 1) }
    }

    /// Subtle opacity pulse for redacted placeholder content.
    func skeletonPulse() -> some View {
        phaseAnimator([1.0, 0.55]) { view, phase in
            view.opacity(phase)
        } animation: { _ in
            .easeInOut(duration: 0.9)
        }
    }

    /// Light-context floating chrome and cards: one material, one hairline,
    /// one shadow.
    func floatingSurface(cornerRadius: CGFloat = DesignTokens.panelCornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.regularMaterial, in: shape)
            .overlay { shape.stroke(Color.primary.opacity(DesignTokens.hairlineOpacity), lineWidth: 1) }
            .shadow(
                color: .black.opacity(DesignTokens.floatingShadowOpacity),
                radius: DesignTokens.floatingShadowRadius,
                y: DesignTokens.floatingShadowYOffset
            )
    }

    func cardShadow() -> some View {
        shadow(
            color: .black.opacity(DesignTokens.cardShadowOpacity),
            radius: DesignTokens.cardShadowRadius,
            y: DesignTokens.cardShadowYOffset
        )
    }
}

/// Press-down feedback for tappable cards; pair with plain content labels.
struct PressableCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
