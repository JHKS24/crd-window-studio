import AppKit
import CRDSettingsCore
import SwiftUI

/// The helper's own sharing window for each built-in shape, drawn with the app's preview
/// (handle, inset grip, Stop pill in the chosen style), plus the Stop capsule a double-click
/// opens on the dot. Used only for snapshots.
struct HelperShapeGallery: View {
    let schema: SettingsSchema
    /// The stopStyle setting every Stop is drawn in.
    var stopStyle = "red"
    var body: some View {
        let items = schema.shapes.filter { $0.id != "custom" }
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color(nsColor: .systemTeal).opacity(0.2), Color(nsColor: .systemIndigo).opacity(0.25)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(items) { shape in
                    HStack(alignment: .center, spacing: 16) {
                        Text(shape.localizedTitle).font(.callout.weight(.medium)).frame(width: 120, alignment: .leading)
                        HelperWindowDrawing(values: values(for: shape))
                    }
                }
                HStack(alignment: .center, spacing: 16) {
                    Text(L10n.text("두 번 클릭한 뒤")).font(.callout.weight(.medium)).frame(width: 120, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    ExpandedStopCapsule(values: values(for: items.first(where: { $0.id == "dot" }) ?? items[0]))
                }
            }
            .padding(28)
        }
    }
    /// The default settings with `shape` applied in custom mode.
    private func values(for shape: ShapePreset) -> [String: ConfigValue] {
        var values = schema.defaults
        values["mode"] = .string("custom")
        values.merge(shape.values) { $1 }
        values["shape"] = .string(shape.id)
        values["stopStyle"] = .string(stopStyle)
        return values
    }
}

/// The capsule's parts, as `CapsuleLayout()` in backend/OverlayMain.mm lays them out
/// (origin top-left here): 6 pt around the pill, the dot 12 pt from the left end and 10 pt
/// before the pill, and a pill wide enough for a 120 x 36 pt press area. The capsule always
/// has its dot, so a double-click outside Stop has a place to fold it.
struct StopCapsuleLayout {
    static let padding: CGFloat = 6, dotInset: CGFloat = 12, dotGap: CGFloat = 10, dotDiameter: CGFloat = 12
    static let hitWidth: CGFloat = 120, pillMaximumWidth: CGFloat = 280
    var size: CGSize
    var dot: CGRect
    var pill: CGRect
    /// Lays the capsule out for the pill's natural size and the dot's diameter.
    init(pill natural: CGSize, dot diameter: CGFloat) {
        let height = max(natural.height, diameter) + 2 * Self.padding
        let inset = ((height - natural.height) / 2).rounded()
        let pillX = Self.dotInset + diameter + Self.dotGap
        // The press area starts half the gap before the pill.
        let width = min(Self.pillMaximumWidth, max(natural.width, Self.hitWidth - Self.dotGap / 2 - inset))
        size = CGSize(width: pillX + width + inset, height: height)
        pill = CGRect(x: pillX, y: inset, width: width, height: natural.height)
        dot = CGRect(x: Self.dotInset, y: (height - diameter) / 2, width: diameter, height: diameter)
    }
    /// The capsule for a window's settings, with the dot `diameter(for:)` gives.
    init(pill natural: CGSize, values: [String: ConfigValue]) { self.init(pill: natural, dot: Self.diameter(for: values)) }
    /// The capsule's dot diameter, the helper's rule: in the dot layout the window's own dot,
    /// min(dotDiameter, min(width, height)), while that dot is shown; a hidden dot and every other
    /// shape get 12 pt.
    static func diameter(for values: [String: ConfigValue]) -> CGFloat {
        guard values["layout"]?.string == "dot", values["showDot"]?.bool == true else { return dotDiameter }
        return CGFloat(min(values["dotDiameter"]?.number ?? 0, min(values["width"]?.number ?? 0, values["height"]?.number ?? 0)))
    }
}

/// The Stop capsule the helper opens on a double-click of any shape: the dot on the left and
/// the Stop pill on the right, in the background color with the accent border. The dot is drawn
/// in the dot color at the size `StopCapsuleLayout.diameter(for:)` gives, even when the window's
/// own dot is hidden.
struct ExpandedStopCapsule: View {
    let values: [String: ConfigValue]
    var body: some View {
        let title = L10n.buttonTitle(values["buttonText"]?.string ?? "")
        let font = NSFont.systemFontSize
        let layout = StopCapsuleLayout(pill: StopPill.size(title: title, font: font), values: values)
        let accent = values["accent"]?.string ?? "system"
        let dotValue = values["dotColor"]?.string ?? "accent"
        let dotColor = Color.configuration(dotValue == "accent" ? accent : dotValue, fallback: Color(nsColor: .controlAccentColor))
        let border = min(values["borderWidth"]?.number ?? 0, layout.size.height / 2)
        ZStack(alignment: .topLeading) {
            Capsule().fill(Color.configuration(values["background"]?.string ?? "system", fallback: Color(nsColor: .windowBackgroundColor)))
                .overlay { if border > 0 { Capsule().stroke(Color.configuration(accent, fallback: Color(nsColor: .controlAccentColor)), lineWidth: border) } }
                .frame(width: layout.size.width, height: layout.size.height)
            Circle().fill(dotColor).frame(width: layout.dot.width, height: layout.dot.height)
                .offset(x: layout.dot.minX, y: layout.dot.minY)
            StopButtonView(title: title, font: font, style: values["stopStyle"]?.string ?? "red")
                .frame(width: layout.pill.width, height: layout.pill.height)
                .offset(x: layout.pill.minX, y: layout.pill.minY)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }
}
