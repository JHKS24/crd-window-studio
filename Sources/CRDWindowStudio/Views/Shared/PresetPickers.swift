import SwiftUI
import CRDSettingsCore

/// Both pickers mark the selection the same way: a 2 pt accent stroke on a 7 pt radius.
enum PickerSelection {
    static let cornerRadius: CGFloat = 7
    static func stroke(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1)
    }
}

/// The light, dark and system appearance choices as small window drawings.
struct AppearanceThumbnailPicker: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        HStack(spacing: 16) {
            ForEach(store.schema.choices["appearance", default: []]) { choice in
                Button {
                    store.set("appearance", .string(choice.id))
                } label: {
                    VStack(spacing: 7) {
                        AppearanceThumbnail(mode: choice.id)
                            .frame(width: 82, height: 54)
                            .overlay(PickerSelection.stroke(selected: store.string("appearance") == choice.id))
                        Text(choice.localizedTitle).font(.callout)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format("화면 모드: %@", choice.localizedTitle))
                .accessibilityAddTraits(store.string("appearance") == choice.id ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
/// A window drawing in the given appearance; the system choice shows light and dark halves.
private struct AppearanceThumbnail: View {
    let mode: String
    @Environment(\.colorScheme) private var surrounding
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // On a dark page the light drawing is dimmed a little so it does not glare.
                windowDrawing.environment(\.colorScheme, mode == "dark" ? .dark : .light)
                    .overlay { if mode != "dark" && surrounding == .dark { Color.black.opacity(0.14) } }
                if mode == "system" { windowDrawing.environment(\.colorScheme, .dark) }
            }
            .clipShape(RoundedRectangle(cornerRadius: PickerSelection.cornerRadius))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }
    private var windowDrawing: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(0..<3) { _ in Capsule().fill(.tertiary).frame(height: 3) }
                Spacer(minLength: 0)
            }.padding(7).frame(maxWidth: .infinity).background(.quaternary)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(.secondary).frame(height: 3)
                RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 15)
                Spacer(minLength: 0)
            }.padding(7).frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The built-in window shapes as a grid of thumbnails.
struct ShapePresetPicker: View {
    @ObservedObject var store: SettingsStore
    /// Six shapes in three even columns, two full rows.
    private let columns = Array(repeating: GridItem(.flexible(minimum: 96), spacing: 12), count: 3)
    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(store.schema.shapes) { shape in
                Button { store.chooseShape(shape.id) } label: {
                    VStack(spacing: 7) {
                        ShapeThumbnail(shape: shape)
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: PickerSelection.cornerRadius))
                            .overlay(PickerSelection.stroke(selected: store.string("shape") == shape.id))
                        Text(shape.localizedTitle).font(.callout)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityLabel(L10n.format("창 모양: %@", shape.localizedTitle))
                .accessibilityAddTraits(store.string("shape") == shape.id ? .isSelected : [])
            }
        }.padding(.vertical, 6)
    }
}
/// A scaled drawing of a shape with its dot, text and Stop button; the custom shape shows its symbol.
private struct ShapeThumbnail: View {
    let shape: ShapePreset
    var body: some View {
        GeometryReader { geometry in
            if shape.id == "custom" {
                Image(systemName: shape.symbol).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let w = max(1, shape.values["width"]?.number ?? 100)
                let h = max(1, shape.values["height"]?.number ?? 40)
                let scale = min((geometry.size.width - 24) / w, (geometry.size.height - 16) / h)
                let displayWidth = w * scale
                let displayHeight = h * scale
                HStack(spacing: 5) {
                    if shape.values["showDot"]?.bool == true { Circle().fill(.tint).frame(width: 5, height: 5) }
                    if shape.values["showText"]?.bool == true { Capsule().fill(.secondary).frame(width: max(8, displayWidth * 0.35), height: 3) }
                    if shape.values["showStopButton"]?.bool == true { RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: max(8, displayWidth * 0.22), height: 8) }
                }
                .frame(width: displayWidth, height: displayHeight)
                .background(.background, in: RoundedRectangle(cornerRadius: (shape.values["radius"]?.number ?? 10) * scale))
                .overlay(RoundedRectangle(cornerRadius: (shape.values["radius"]?.number ?? 10) * scale).strokeBorder(.separator, lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.accessibilityHidden(true)
    }
}
