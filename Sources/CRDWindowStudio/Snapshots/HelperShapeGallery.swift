import AppKit
import CRDSettingsCore
import SwiftUI

/// The helper's own sharing window for each built-in shape, drawn with the app's preview
/// (handle, inset grip, red Stop button), plus the status dot's Stop capsule with its red
/// bordered button. Used only for snapshots.
struct HelperShapeGallery: View {
    let schema: SettingsSchema
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
                    Text(L10n.text("상태 점을 펼친 뒤")).font(.callout.weight(.medium)).frame(width: 120, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    ExpandedDotDrawing(values: values(for: items.first(where: { $0.id == "dot" }) ?? items[0]))
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
        return values
    }
}

/// The stop capsule the helper opens on a double click of the status dot:
/// background widened around the dot's center, dot on the left, stop on the right.
/// It uses the same geometry as the helper's Stop reveal: Stop is the bar's button (its height and bezel)
/// as wide as the press area, after the dot's own inset, with an end inset equal to the space above it.
struct ExpandedDotDrawing: View {
    let values: [String: ConfigValue]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let anchor = CGSize(width: values["width"]?.number ?? 40, height: values["height"]?.number ?? 40)
        let title = L10n.text("공유 중지")
        let font = NSFont.systemFontSize
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: font)]).width)
        let hit = CGSize(width: max(120, titleWidth + 24), height: 36)
        let height = max(anchor.height, hit.height + 4)
        let bezel = CGSize(width: hit.width, height: min(hit.height, max(24, HelperOverlayLayout.stopButtonSize(title: title, font: font).height)))
        let endInset = max(2, ((height - bezel.height) / 2).rounded())
        let width = max(anchor.width, height + hit.width + endInset)
        let stopX = height + max(0, (width - height - hit.width - endInset) / 2)
        let diameter = min(values["dotDiameter"]?.number ?? 10, min(anchor.width, anchor.height))
        let accent = values["accent"]?.string ?? "system"
        let dotValue = values["dotColor"]?.string ?? "accent"
        let dotColor = Color.configuration(dotValue == "accent" ? accent : dotValue, fallback: Color(nsColor: .controlAccentColor))
        ZStack(alignment: .topLeading) {
            Capsule().fill(Color.configuration(values["background"]?.string ?? "system", fallback: Color(nsColor: .windowBackgroundColor)))
                .frame(width: width, height: height)
            Circle().fill(dotColor).frame(width: diameter, height: diameter)
                .offset(x: (height - diameter) / 2, y: (height - diameter) / 2)
            StopButtonView(title: title, font: font, dark: scheme == .dark)
                .frame(width: bezel.width, height: bezel.height)
                .offset(x: stopX, y: ((height - bezel.height) / 2).rounded())
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }
}
