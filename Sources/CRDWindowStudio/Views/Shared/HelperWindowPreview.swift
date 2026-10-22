import AppKit
import CRDSettingsCore
import SwiftUI

/// Mirrors `Layout()` in backend/OverlayMain.mm so the previews show what the
/// helper draws: the same frames for the move handle, resize grip (inset from
/// rounded corners), dot, text and red stop button, the accent-colored border,
/// the one-line text and the "●" glyph. Coordinates follow AppKit (origin
/// bottom-left) and are flipped on draw.
struct HelperOverlayLayout {
    struct Element { var frame: CGRect; var visible: Bool }
    var size: CGSize
    var handle = Element(frame: .zero, visible: false)
    var resize = Element(frame: .zero, visible: false)
    var dot = Element(frame: .zero, visible: false)
    var label = Element(frame: .zero, visible: false)
    var stop = Element(frame: .zero, visible: false)
    var dotLayout = false
    var column = false
    var font: CGFloat = NSFont.systemFontSize

    /// Lays out the handle, the resize grip, the dot, the text and the Stop button for one of the
    /// three layouts (dot, column or row), dropping any element that does not fit.
    init(values: [String: ConfigValue], stopTitle: String) {
        func n(_ key: String) -> CGFloat { CGFloat(values[key]?.number ?? 0) }
        func b(_ key: String) -> Bool { values[key]?.bool ?? false }
        func s(_ key: String) -> String { values[key]?.string ?? "" }
        let w = max(1, n("width")), h = max(1, n("height"))
        size = CGSize(width: w, height: h)
        dotLayout = s("layout") == "dot"
        column = s("layout") == "column"
        let handleSize = n("handleSize"), handleGap: CGFloat = 4
        var handleLeft: CGFloat = 0, handleRight: CGFloat = 0, handleTop: CGFloat = 0
        if !dotLayout && b("showHandle") && w >= handleSize && h >= handleSize {
            handle.visible = true
            switch s("handlePosition") {
            case "top": handle.frame = CGRect(x: (w - handleSize) / 2, y: h - handleSize - 2, width: handleSize, height: handleSize); handleTop = handleSize + handleGap
            case "trailing": handle.frame = CGRect(x: w - handleSize - 2, y: (h - handleSize) / 2, width: handleSize, height: handleSize); handleRight = handleSize + handleGap
            default: handle.frame = CGRect(x: 2, y: (h - handleSize) / 2, width: handleSize, height: handleSize); handleLeft = handleSize + handleGap
            }
        }
        if !dotLayout && b("resizable") && w >= 80 && h >= 24 {
            // GripInset(): 1 - 1/sqrt(2) of the corner radius reaches the arc; a full capsule end gets 3 pt more.
            let corner = max(0, min(n("radius"), min(w, h) / 2))
            let inset = (corner * 0.293).rounded() + (corner > 0 && corner >= min(w, h) / 2 - 0.5 ? 3 : 0)
            resize = Element(frame: CGRect(x: w - 11 - inset, y: inset, width: 11, height: 11), visible: true)
        }
        font = n("fontSize") == 0 ? NSFont.systemFontSize : n("fontSize")
        let systemFont = NSFont.systemFont(ofSize: font)
        let line = ceil(systemFont.ascender - systemFont.descender) + 4
        let pad = min(12, min(w, h) / 4), gap: CGFloat = 8, dotWidth = max(12, font + 4)
        let button = Self.stopButtonSize(title: stopTitle, font: font)
        var buttonW = max(36, button.width)
        let buttonH = max(24, button.height)
        if dotLayout {
            if b("showDot") { dot = Element(frame: CGRect(x: 0, y: 0, width: w, height: h), visible: true) }
        } else if column {
            let inner = max(0, w - 2 * pad - handleLeft - handleRight)
            // A top handle sits in the top padding instead of adding to it (the helper's Layout()).
            var top = h - (handleTop > 0 ? max(pad, handleTop + 2) : pad)
            let centerX = handleLeft + (w - handleLeft - handleRight) / 2
            if b("showStopButton") && inner >= 36 && h >= buttonH + 2 * pad {
                buttonW = min(buttonW, inner)
                stop = Element(frame: CGRect(x: centerX - buttonW / 2, y: pad, width: buttonW, height: buttonH), visible: true)
            }
            let floor = stop.visible ? stop.frame.maxY + gap : pad
            if b("showDot") && inner >= dotWidth && top - floor >= line {
                dot = Element(frame: CGRect(x: centerX - dotWidth / 2, y: top - line, width: dotWidth, height: line), visible: true)
                top -= line + gap
            }
            if b("showText") && inner >= 12 && top - floor >= line {
                label = Element(frame: CGRect(x: pad + handleLeft, y: top - line, width: inner, height: line), visible: true)
            }
        } else {
            var left = pad + handleLeft, right = w - pad - handleRight
            let available = h - handleTop
            // The stop button stays clear of the grip when their heights overlap.
            if resize.visible && (available - buttonH) / 2 < resize.frame.maxY + 1 { right = min(right, resize.frame.minX - 2) }
            if b("showStopButton") && available >= buttonH && right - left >= 36 {
                buttonW = min(buttonW, right - left)
                stop = Element(frame: CGRect(x: right - buttonW, y: (available - buttonH) / 2, width: buttonW, height: buttonH), visible: true)
                right -= buttonW + gap
            }
            if b("showDot") && available >= line && right - left >= dotWidth {
                dot = Element(frame: CGRect(x: left, y: (available - line) / 2, width: dotWidth, height: line), visible: true)
                left += dotWidth + gap
            }
            if b("showText") && available >= line && right - left >= 12 {
                label = Element(frame: CGRect(x: left, y: (available - line) / 2, width: right - left, height: line), visible: true)
            }
        }
    }
    /// The fitted size of an AppKit rounded button with `title` at `font` points, cached per title and size.
    @MainActor private static var buttonSizes: [String: CGSize] = [:]
    static func stopButtonSize(title: String, font: CGFloat) -> CGSize {
        MainActor.assumeIsolated {
            let key = "\(font)|\(title)"
            if let size = buttonSizes[key] { return size }
            let button = NSButton(title: title, target: nil, action: nil)
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: font)
            button.sizeToFit()
            buttonSizes[key] = button.frame.size
            return button.frame.size
        }
    }
    /// SwiftUI origin is top-left.
    func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height) }
}

/// The helper window drawn from the store's values, or from `values` when given.
struct HelperWindowPreview: View {
    @ObservedObject var store: SettingsStore
    var values: [String: ConfigValue]?
    var body: some View {
        HelperWindowDrawing(values: values ?? store.values)
    }
}

/// The real-size preview window saves its position and size as soon as it
/// is moved or resized, and says so in a note.
/// The note sits in a band below the title bar, so it never shortens the title. A bottom
/// accessory is part of the window's frame-to-content mapping (`contentRect(forFrameRect:)`), so
/// the content keeps the helper's exact size and the saved geometry is unchanged. With both
/// locks on, nothing can be moved or resized, so the note is hidden.
enum PreviewWindowNote {
    static let identifier = NSUserInterfaceItemIdentifier("CRDPreviewSaveNote")
    static var text: String { L10n.text("옮기거나 크기를 바꾸면 바로 저장됩니다") }
    /// True unless both locks are on.
    static func shows(_ values: [String: ConfigValue]) -> Bool {
        values["draggable"]?.bool != false || values["resizable"]?.bool != false
    }
    /// Adds the note as a bottom title bar accessory, once per window.
    @MainActor static func install(on window: NSWindow) {
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == identifier }) else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        label.sizeToFit()
        let height: CGFloat = 24
        let container = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 24, height: height))
        label.frame = NSRect(x: 12, y: ((height - label.frame.height) / 2).rounded(), width: label.frame.width, height: label.frame.height)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        container.addSubview(label)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = identifier
        accessory.view = container
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)
    }
    /// Shows or hides the installed note; AppKit gives its height back to the content.
    @MainActor static func update(on window: NSWindow, values: [String: ConfigValue]) {
        for accessory in window.titlebarAccessoryViewControllers where accessory.identifier == identifier {
            let hidden = !shows(values)
            if accessory.isHidden != hidden { accessory.isHidden = hidden }
        }
    }
    /// Removes the note from a titled window.
    @MainActor static func remove(from window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        for index in window.titlebarAccessoryViewControllers.indices.reversed()
        where window.titlebarAccessoryViewControllers[index].identifier == identifier {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }
}

/// Draws the helper's window from settings values: background, border, handle, grip, dot, text and
/// Stop button at the frames HelperOverlayLayout computes, with the window's opacity and shadow.
struct HelperWindowDrawing: View {
    let values: [String: ConfigValue]
    @Environment(\.colorScheme) private var inherited
    private func string(_ key: String) -> String { values[key]?.string ?? "" }
    private func number(_ key: String) -> Double { values[key]?.number ?? 0 }
    private func bool(_ key: String) -> Bool { values[key]?.bool ?? false }
    private var scheme: ColorScheme {
        switch string("appearance") { case "light": return .light; case "dark": return .dark; default: return inherited }
    }
    private var stopTitle: String { L10n.buttonTitle(string("buttonText")) }
    private var message: String { string("text").isEmpty ? L10n.text("화면을 공유하고 있습니다") : string("text") }
    private var accent: Color { .configuration(string("accent"), fallback: Color(nsColor: .controlAccentColor)) }
    private var dotColor: Color {
        let value = string("dotColor")
        return .configuration(value == "accent" ? string("accent") : value, fallback: Color(nsColor: .controlAccentColor))
    }
    var body: some View {
        let layout = HelperOverlayLayout(values: values, stopTitle: stopTitle)
        let w = layout.size.width, h = layout.size.height
        let border = min(number("borderWidth"), min(w, h))
        let inner = CGSize(width: max(0, w - border), height: max(0, h - border))
        let radius = max(0, min(number("radius"), min(inner.width, inner.height) / 2))
        let draggable = bool("draggable")
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.configuration(string("background"), fallback: Color(nsColor: .windowBackgroundColor)))
                .overlay { if border > 0 { RoundedRectangle(cornerRadius: radius).stroke(accent, lineWidth: border) } }
                .frame(width: inner.width, height: inner.height)
                .offset(x: border / 2, y: border / 2)
            if layout.handle.visible {
                place(layout.flipped(layout.handle.frame)) { HandleDots(opacity: number("handleOpacity") * (draggable ? 1 : 0.5)) }
            }
            if layout.resize.visible {
                place(layout.flipped(layout.resize.frame)) { ResizeGrip(opacity: number("handleOpacity") * (bool("resizable") ? 1 : 0.5)) }
            }
            if layout.dot.visible {
                place(layout.flipped(layout.dot.frame)) {
                    if layout.dotLayout {
                        let d = min(number("dotDiameter"), min(w, h))
                        Circle().fill(dotColor).frame(width: d, height: d)
                    } else {
                        Text(verbatim: "●").font(.system(size: layout.font)).foregroundStyle(dotColor)
                    }
                }
            }
            if layout.label.visible {
                place(layout.flipped(layout.label.frame), alignment: layout.column ? .center : .leading) {
                    Text(message).font(.system(size: layout.font)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(Color.configuration(string("foreground"), fallback: Color(nsColor: .labelColor)))
                }
            }
            if layout.stop.visible {
                place(layout.flipped(layout.stop.frame)) {
                    StopButtonView(title: stopTitle, font: layout.font, dark: scheme == .dark)
                }
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .compositingGroup()
        .opacity(number("opacity"))
        .shadow(color: .black.opacity(bool("shadow") ? 0.22 : 0), radius: 8, y: 3)
        .environment(\.colorScheme, scheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("공유 창 미리보기"))
    }
    /// Places `content` in `rect`, given in top-left coordinates.
    private func place<Content: View>(_ rect: CGRect, alignment: Alignment = .center, @ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: rect.width, height: rect.height, alignment: alignment).offset(x: rect.minX, y: rect.minY)
    }
}

/// The move handle: two columns of three dots.
private struct HandleDots: View {
    let opacity: Double
    var body: some View {
        GeometryReader { geometry in
            let spacing = min(4, min(geometry.size.width, geometry.size.height) / 3.5)
            let diameter = max(1.4, spacing / 2)
            ForEach(0..<6, id: \.self) { index in
                let column = CGFloat(index / 3), row = CGFloat(index % 3)
                Circle().fill(Color(nsColor: .secondaryLabelColor).opacity(opacity))
                    .frame(width: diameter, height: diameter)
                    .position(x: geometry.size.width / 2 + (column - 0.5) * spacing, y: geometry.size.height / 2 + (row - 1) * spacing)
            }
        }
    }
}

/// The resize grip: three diagonal lines in the bottom-right corner.
private struct ResizeGrip: View {
    let opacity: Double
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for offset in stride(from: 2.0, through: 8.0, by: 3.0) {
                path.move(to: CGPoint(x: size.width - offset, y: size.height - 2))
                path.addLine(to: CGPoint(x: size.width - 2, y: size.height - offset))
            }
            context.stroke(path, with: .color(Color(nsColor: .secondaryLabelColor).opacity(opacity)), lineWidth: 1)
        }
    }
}

/// The helper uses an AppKit rounded destructive button with a red title
/// (StyleStopTitle()). The preview draws the same control; it has no action.
struct StopButtonView: NSViewRepresentable {
    let title: String
    let font: CGFloat
    var dark = false
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(L10n.text("공유 중지 버튼 미리보기"))
        button.toolTip = L10n.text("미리보기에서는 공유를 중지할 수 없습니다.")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.font = .systemFont(ofSize: font)
        button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        button.hasDestructiveAction = true
        // A bordered push button ignores contentTintColor for its title; color the title itself.
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: font), .foregroundColor: NSColor.systemRed])
    }
}

/// Fits a preview into the available space without enlarging it.
struct ScaledPreview<Content: View>: View {
    let size: CGSize
    var padding: CGFloat = 8
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            let scale = min(1, max(0.01, (geometry.size.width - 2 * padding) / size.width), max(0.01, (geometry.size.height - 2 * padding) / size.height))
            content()
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
