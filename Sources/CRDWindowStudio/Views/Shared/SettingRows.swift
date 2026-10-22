import AppKit
import CRDSettingsCore
import SwiftUI

// MARK: - Number and percent rows
// Inline range checks instead of modal alerts, units and steppers on numbers, readable values
// on sliders.

/// The unit label shown after a number field.
enum StudioUnit {
    case points, seconds, none
    var label: String {
        switch self { case .points: return "pt"; case .seconds: return L10n.text("초"); case .none: return "" }
    }
}

/// Number formatting and parsing for the fields: up to two decimals, no grouping, and a comma
/// accepted as the decimal separator.
enum StudioNumber {
    static func text(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) }
    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
    }
}

/// A number setting: a bordered field, its unit and a stepper, limited to the schema's range.
/// A typed value is staged as a draft, so quitting the app still saves it, and is applied when the
/// field is submitted or loses focus. An invalid value shows a message and restores the stored one.
struct NumberRow: View {
    let title: String
    let key: String
    @ObservedObject var store: SettingsStore
    var unit: StudioUnit = .points
    var hint: String?
    /// A narrower range than the schema's, for a field that is one of several ways to set a key.
    var limits: ClosedRange<Double>?
    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var focused: Bool
    private var range: ClosedRange<Double> {
        if let limits { return limits }
        let limits = store.schema.numericLimits[key, default: [-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude]]
        return limits[0]...limits[1]
    }
    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                // A bordered field, so an editable value never reads as a status label.
                TextField(title, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden().multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .focused($focused)
                    .onSubmit(commit)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(draft) \(unit.label)")
                    .accessibilityIdentifier("number-\(key)")
                if !unit.label.isEmpty { Text(unit.label).foregroundStyle(.secondary).frame(minWidth: 16, alignment: .leading) }
                Stepper(title, value: Binding(get: { store.number(key) }, set: { apply(min(max($0, range.lowerBound), range.upperBound)) }),
                        in: range, step: 1)
                    .labelsHidden().fixedSize()
            }
        } label: {
            // A short hint reads as secondary text beside the title; a problem still goes below it.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                    if let hint, problem == nil { Text(hint).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            }
        }
        .help(L10n.format("%@~%@ 사이의 값", StudioNumber.text(range.lowerBound), StudioNumber.text(range.upperBound)))
        .onAppear(perform: synchronize)
        .onChange(of: store.number(key)) { _, _ in if !focused { synchronize() } }
        .onChange(of: focused) { _, now in if !now { commit() } }
        .onChange(of: draft) { _, text in if focused { stage(text) } }
        .onDisappear { if focused { commit() } }
    }
    private func synchronize() { draft = StudioNumber.text(store.number(key)) }
    /// A valid uncommitted number is saved if the app quits first.
    private func stage(_ text: String) {
        let store = store, key = key, range = range
        store.stageDraft("number-\(key)") {
            guard let number = StudioNumber.parse(text), range.contains(number),
                  let changes = NumericEdit.changes(key: key, number: number, current: store.values) else { return }
            store.update(changes)
        }
    }
    private func commit() {
        store.clearDraft("number-\(key)")
        guard let number = StudioNumber.parse(draft) else {
            problem = L10n.text("숫자를 입력하세요.")
            synchronize(); return
        }
        guard range.contains(number) else {
            problem = L10n.format("%@~%@ 사이의 값을 입력하세요.", StudioNumber.text(range.lowerBound), StudioNumber.text(range.upperBound))
            synchronize(); return
        }
        apply(number)
    }
    private func apply(_ number: Double) {
        problem = nil
        // Width, height and corner radius changes clear the preset; an unchanged number saves nothing.
        if let changes = NumericEdit.changes(key: key, number: number, current: store.values) { store.update(changes) }
        synchronize()
    }
}

/// A 0 to 1 setting as a slider with its percentage, rounded to whole percent.
struct PercentRow: View {
    let title: String
    let key: String
    @ObservedObject var store: SettingsStore
    private var range: ClosedRange<Double> {
        let limits = store.schema.numericLimits[key, default: [0, 1]]
        return limits[0]...limits[1]
    }
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { store.number(key) }, set: { store.set(key, .number(($0 * 100).rounded() / 100)) }), in: range)
                    .frame(minWidth: 120, maxWidth: 200)
                    .accessibilityLabel(title)
                    .accessibilityValue(Text(store.number(key), format: .percent.precision(.fractionLength(0))))
                Text(store.number(key), format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - Display mode

/// Mode titles and explanations in plain words. The schema ids stay the same.
enum StudioMode {
    static let order = ["custom", "original"]
    static func title(_ id: String) -> String {
        switch id {
        case "custom": return L10n.text("꾸민 창")
        default: return L10n.text("원래 공유 창")
        }
    }
    static func explanation(_ id: String) -> String {
        switch id {
        case "custom": return L10n.text("원래 공유 창 대신 꾸민 창을 보여 줍니다.")
        default: return L10n.text("Chrome 원격 데스크톱의 원래 공유 창을 그대로 보여 줍니다.")
        }
    }
    @MainActor static func binding(_ store: SettingsStore) -> Binding<String> {
        Binding(get: { store.string("mode") }, set: { store.set("mode", .string($0)) })
    }
    /// The custom window settings apply only while this is true.
    @MainActor static func customInEffect(_ store: SettingsStore) -> Bool { store.bool("enabled") && store.string("mode") == "custom" }
}

/// One display mode per form row, its radio mark on the leading edge before the title and
/// the explanation; a click anywhere in the row selects it. VoiceOver reads it as a selectable button.
struct ModeRadioRow: View {
    let id: String
    @ObservedObject var store: SettingsStore
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        let selected = store.string("mode") == id
        Button { store.set("mode", .string(id)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RadioMark(selected: selected).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(StudioMode.title(id)).foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                    Text(StudioMode.explanation(id)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StudioMode.title(id))
        .accessibilityHint(StudioMode.explanation(id))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// A radio mark drawn like the system one: accent fill with a white center when selected.
private struct RadioMark: View {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        ZStack {
            Circle().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
            if !selected { Circle().strokeBorder(Color.primary.opacity(0.28), lineWidth: 1) }
            if selected { Circle().fill(Color.white).frame(width: 6, height: 6) }
        }
        .frame(width: 14, height: 14)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityHidden(true)
    }
}

/// The display mode as a menu, a segmented control or a radio group.
struct ModePicker: View {
    enum Style { case menu, segmented, radio }
    @ObservedObject var store: SettingsStore
    var style: Style = .segmented
    var body: some View {
        switch style {
        case .menu:
            Picker(L10n.text("표시 방식"), selection: StudioMode.binding(store)) {
                ForEach(StudioMode.order, id: \.self) { Text(StudioMode.title($0)).tag($0) }
            }.pickerStyle(.menu)
        case .segmented:
            Picker(L10n.text("표시 방식"), selection: StudioMode.binding(store)) {
                ForEach(StudioMode.order, id: \.self) { Text(StudioMode.title($0)).tag($0) }
            }.pickerStyle(.segmented)
        case .radio:
            Picker(L10n.text("표시 방식"), selection: StudioMode.binding(store)) {
                ForEach(StudioMode.order, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(StudioMode.title(id))
                        Text(StudioMode.explanation(id)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                    .tag(id)
                }
            }.pickerStyle(.radioGroup)
        }
    }
}

// MARK: - Choice, color and text rows
/// A choice setting from the schema as a menu or a segmented control; `titles` overrides option titles.
struct ChoiceRow: View {
    let title: String
    let key: String
    @ObservedObject var store: SettingsStore
    var titles: [String: String] = [:]
    var segmented = false
    var body: some View {
        let picker = Picker(title, selection: Binding(get: { store.string(key) }, set: { store.set(key, .string($0)) })) {
            ForEach(store.schema.choices[key, default: []]) { choice in Text(titles[choice.id] ?? choice.localizedTitle).tag(choice.id) }
        }
        if segmented { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
    }
}

/// The display picker. A saved display that is not connected stays listed, marked as shown on the first display.
/// Snapshots name every display generically, so no real display name reaches a rendered image.
struct DisplayRow: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Picker(L10n.text("디스플레이"), selection: Binding(get: { Int(store.number("screen")) }, set: { store.set("screen", .number(Double($0))) })) {
            ForEach(Array(store.screens.enumerated()), id: \.offset) { index, screen in
                Text(L10n.format("%@. %@", index + 1, AppRuntime.renderingSnapshots ? L10n.text("디스플레이") : screen.localizedName)).tag(index)
            }
            if Int(store.number("screen")) >= store.screens.count {
                Text(L10n.format("디스플레이 %@(연결 안 됨, 첫 번째 디스플레이에 표시)", Int(store.number("screen")) + 1)).tag(Int(store.number("screen")))
            }
        }.pickerStyle(.menu)
    }
}

/// A color setting: the palette or system color, or a custom color with a color well.
struct ColorRow: View {
    let title: String
    let key: String
    @ObservedObject var store: SettingsStore
    private var choice: String { store.string(key).hasPrefix("#") ? "custom" : store.string(key) }
    private var fallback: Color {
        switch key {
        case "background": return Color(nsColor: .windowBackgroundColor)
        case "foreground": return Color(nsColor: .labelColor)
        default: return Color(nsColor: .controlAccentColor)
        }
    }
    private var effective: Color { key == "dotColor" ? store.dotColor : .configuration(store.string(key), fallback: fallback) }
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if choice == "custom" {
                    ColorPicker(title, selection: Binding(get: { effective }, set: { color in
                        if let hex = color.hexRGB { store.set(key, .string(hex)) }
                    }), supportsOpacity: false).labelsHidden()
                }
                Picker(title, selection: Binding(get: { choice }, set: { new in
                    // A custom color starts from the color in use, not from gray.
                    store.set(key, .string(new == "custom" ? (effective.hexRGB ?? "#808080") : new))
                })) {
                    if key == "dotColor" { Text(L10n.text("강조 색상 따르기")).tag("accent") }
                    if key == "accent" || key == "dotColor" {
                        ForEach(store.schema.choices["accent", default: []]) { option in
                            Text(option.id == "system" ? L10n.text("시스템 강조 색상") : option.localizedTitle).tag(option.id)
                        }
                    } else { Text(L10n.text("시스템 기본")).tag("system") }
                    Divider()
                    Text(L10n.text("직접 선택")).tag("custom")
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
        }
    }
}

/// A text setting. The default Stop button title shows as an empty field, and saving an empty field
/// keeps that default. Typed text is staged as a draft and applied on submit or when focus leaves.
struct TextRow: View {
    let title: String
    let key: String
    @ObservedObject var store: SettingsStore
    var placeholder = ""
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $draft, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(minWidth: 140, idealWidth: 220, maxWidth: 280)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityIdentifier("text-\(key)")
        }
        .onAppear { draft = editable(store.string(key)) }
        .onChange(of: store.string(key)) { _, new in if !focused { draft = editable(new) } }
        .onChange(of: focused) { _, now in if !now { commit() } }
        .onChange(of: draft) { _, text in
            guard focused else { return }
            let store = store, key = key
            store.stageDraft("text-\(key)") { Self.save(text, key: key, store: store) }
        }
        .onDisappear { if focused { commit() } }
    }
    /// The text to edit: empty for the default Stop button title.
    private func editable(_ value: String) -> String {
        key == "buttonText" && value == store.schema.defaults["buttonText"]?.string ? "" : value
    }
    private func commit() {
        store.clearDraft("text-\(key)")
        Self.save(draft, key: key, store: store); draft = editable(store.string(key))
    }
    /// Saves the text, except an empty Stop button title while the default is stored.
    @MainActor static func save(_ text: String, key: String, store: SettingsStore) {
        if key == "buttonText", text.isEmpty, store.string(key) == store.schema.defaults["buttonText"]?.string { return }
        store.set(key, .string(text))
    }
}

// MARK: - Buttons and toggles

/// Confirmed actions. A destructive one (it overwrites something) has a red title; a reversible
/// one (turning the helper off) is a plain bordered button. Both ask first.
struct ConfirmedButton: View {
    let title: String
    let question: String
    let message: String
    let confirm: String
    var disabled = false
    var destructive = true
    let action: () -> Void
    @State private var asking = false
    var body: some View {
        Group {
            // macOS draws a plain push button for role .destructive; the red title marks it.
            if destructive {
                Button(role: .destructive) { asking = true } label: { Text(title).foregroundStyle(disabled ? Color.secondary : Color.red) }
            } else {
                Button(title) { asking = true }.buttonStyle(.bordered)
            }
        }
        .disabled(disabled)
        .confirmationDialog(question, isPresented: $asking) {
            if destructive { Button(confirm, role: .destructive, action: action) } else { Button(confirm, action: action) }
            Button(L10n.text("취소"), role: .cancel) {}
        } message: { Text(message) }
    }
}

/// A Boolean setting as a toggle.
struct ConfigurationToggle: View {
    let title: String
    let key: String
    @ObservedObject var store: SettingsStore
    var body: some View {
        Toggle(title, isOn: Binding(get: { store.bool(key) }, set: { store.set(key, .bool($0)) }))
    }
}
