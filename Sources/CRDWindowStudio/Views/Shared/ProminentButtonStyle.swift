import AppKit
import SwiftUI

/// The filled accent button for the one main action on a page.
///
/// `.borderedProminent` takes its title color from AppKit's window state. When
/// the window is not key, AppKit draws a dark title while the fill can stay
/// accent blue, which reads poorly in light mode. This style sets the fill and
/// the label together, so they always match: accent fill with a white (or, for
/// a light accent such as yellow, black) label while the window is active, and
/// a neutral fill with the normal label color while it is inactive or disabled.
///
/// Every filled button has one size and one corner radius, whatever the control size
/// around it. In dark mode the inactive state gets a stronger fill and a hairline edge, and the
/// disabled state a fainter fill and label, so the two never look alike. In light mode the inactive
/// state is a 12% fill with the normal label.
struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var colorScheme
    static let cornerRadius: CGFloat = 6
    static let minimumHeight: CGFloat = 22
    static let horizontalPadding: CGFloat = 10
    func makeBody(configuration: Configuration) -> some View {
        let active = isEnabled && activeState != .inactive
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        configuration.label
            .font(.body)
            .lineLimit(1)
            .foregroundStyle(active ? Self.labelOnAccent(dark: dark) : (isEnabled ? Color.primary : (dark ? Color.primary.opacity(0.32) : Color.secondary)))
            .padding(.horizontal, Self.horizontalPadding)
            .frame(minHeight: Self.minimumHeight)
            .background {
                shape
                    .fill(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(Self.neutralFill(enabled: isEnabled, dark: dark))))
                    .overlay {
                        if !active && isEnabled && dark { shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1) }
                        if configuration.isPressed { shape.fill(Color.black.opacity(0.18)) }
                    }
            }
            .contentShape(shape)
    }
    /// The neutral fill: inactive 12% (light) or 20% (dark); disabled 6% (light) or 5% (dark).
    static func neutralFill(enabled: Bool, dark: Bool) -> Double { enabled ? (dark ? 0.20 : 0.12) : (dark ? 0.05 : 0.06) }
    /// White on the accent, except black on a very light accent such as yellow.
    static func labelOnAccent(dark: Bool) -> Color {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        var luminance: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return }
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        return Self.prefersBlackLabel(luminance: luminance) ? .black : .white
    }
    /// macOS puts white on every accent; only a very light fill (yellow, about
    /// 0.6 relative luminance) gets black, as white on it falls below 2:1.
    static func prefersBlackLabel(luminance: CGFloat) -> Bool { luminance > 0.5 }
}

extension ButtonStyle where Self == ProminentButtonStyle {
    static var prominent: ProminentButtonStyle { ProminentButtonStyle() }
}
