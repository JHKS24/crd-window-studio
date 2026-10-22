import AppKit
import CRDSettingsCore
import SwiftUI

/// The fixed preview pane above the two editing pages. The pages show it only
/// while the custom window is in use; otherwise they show CustomOnlyNote.
/// The size and the real-size button sit in the pane's own bottom bar, on the same fill
/// under a hairline, inset like the form cards below. `compact` (a short window) trims the canvas.
struct PreviewPane: View {
    @ObservedObject var store: SettingsStore
    let openPreview: () -> Void
    var compact = false
    static let horizontalInset: CGFloat = 20
    var body: some View {
        let size = CGSize(width: max(1, store.number("width")), height: max(1, store.number("height")))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScaledPreview(size: size, padding: compact ? 10 : 16) { HelperWindowPreview(store: store) }
                ScreenMap(store: store).frame(width: compact ? 96 : 120, height: compact ? 60 : 76).padding(.trailing, Self.horizontalInset)
            }
            .frame(height: compact ? 92 : 132)
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                Text(L10n.format("%@ × %@ pt", Int(store.number("width")), Int(store.number("height"))))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(L10n.text("실제 크기로 보기"), action: openPreview).controlSize(.small)
            }
            .padding(.horizontal, Self.horizontalInset).padding(.vertical, compact ? 4 : 6)
        }
        .background(.quaternary.opacity(0.6))
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A small drawing of the selected display: menu bar, usable area and the
/// window at its computed position (same math as the real-size preview).
struct ScreenMap: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        let screens = store.screens
        let index = min(max(0, Int(store.number("screen"))), max(0, screens.count - 1))
        let frame = screens.isEmpty ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : screens[index].frame
        let visible = screens.isEmpty ? CGRect(x: 0, y: 0, width: 1920, height: 1050) : screens[index].visibleFrame
        let window = Self.windowRect(store: store, visible: visible)
        GeometryReader { geometry in
            let scale = min(geometry.size.width / frame.width, geometry.size.height / frame.height)
            let mapped = { (rect: CGRect) -> CGRect in
                CGRect(x: (rect.minX - frame.minX) * scale, y: (frame.maxY - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale)
            }
            let screen = CGRect(x: 0, y: 0, width: frame.width * scale, height: frame.height * scale)
            // Rounded like the other cards, and the window mark never smaller than 6 x 6 pt
            // (centered on the window), so a status dot stays visible.
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor).opacity(0.85)
                Rectangle().fill(.secondary.opacity(0.35))
                    .frame(width: screen.width, height: max(2, (frame.maxY - visible.maxY) * scale))
                if StudioMode.customInEffect(store) {
                    let mark = Self.mark(mapped(window), in: screen)
                    RoundedRectangle(cornerRadius: min(2, mark.height / 2)).fill(store.accentColor)
                        .frame(width: mark.width, height: mark.height)
                        .offset(x: mark.minX, y: mark.minY)
                }
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.secondary.opacity(0.6)))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityLabel(L10n.text("디스플레이에서의 위치"))
    }
    static let minimumMark: CGFloat = 6
    /// The window's mark, at least 6 x 6 pt around the window's center and kept inside the screen.
    static func mark(_ window: CGRect, in screen: CGRect) -> CGRect {
        let size = CGSize(width: max(minimumMark, window.width), height: max(minimumMark, window.height))
        var origin = CGPoint(x: window.midX - size.width / 2, y: window.midY - size.height / 2)
        origin.x = max(screen.minX, min(origin.x, screen.maxX - size.width))
        origin.y = max(screen.minY, min(origin.y, screen.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }
    /// The window's frame on a screen with `visible` as its usable area, placed as the helper places it.
    @MainActor static func windowRect(store: SettingsStore, visible: CGRect) -> CGRect {
        let size = CGSize(width: store.number("width"), height: store.number("height"))
        var origin: CGPoint
        switch store.string("placement") {
        case "top": origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - store.number("edgeInset"))
        case "bottom": origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + store.number("edgeInset"))
        case "custom": origin = CGPoint(x: visible.minX + store.number("x"), y: visible.maxY - store.number("y") - size.height)
        default: origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        if store.bool("constrainToScreen") {
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        return CGRect(origin: origin, size: size)
    }
}
