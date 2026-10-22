import AppKit
import CRDSettingsCore
import SwiftUI

// Sections the settings pages are built from.

// MARK: - Status and display mode
// The status summary, the main switch and the note shown on custom-only settings.
/// The status icon, title and detail, with the status's main action on the trailing edge.
struct StatusSummaryRow: View {
    @ObservedObject var companion: CompanionService
    @ObservedObject var store: SettingsStore
    var showsAction = true
    var body: some View {
        let status = StudioStatus.make(companion: companion, store: store)
        HStack(alignment: .center, spacing: 12) {
            Group {
                if status.kind == .busy || status.kind == .checking { ProgressView().controlSize(.small).frame(width: 28, height: 28) }
                else { Image(systemName: status.symbol).font(.system(size: 26)).foregroundStyle(status.tint).frame(width: 28, height: 28) }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title).font(.headline)
                Text(status.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if showsAction, let action = status.action, let title = status.actionTitle {
                Button(title) { StudioStatus.perform(action, companion: companion, store: store) }
                    .buttonStyle(.prominent)
                    // The action keeps its full title; the status text beside it wraps instead.
                    .fixedSize()
                    .disabled((companion.busy && action != .openAccessibility && action != .enableSettings) || (action == .retryTurnOff && !companion.canDisable))
            }
        }
        .padding(.vertical, 4)
    }
}

/// The main switch and the display mode picker.
struct SharingSwitchRows: View {
    @ObservedObject var store: SettingsStore
    var modeStyle: ModePicker.Style = .segmented
    var body: some View {
        Toggle(L10n.text("공유 창 바꾸기"), isOn: Binding(get: { store.bool("enabled") }, set: { store.set("enabled", .bool($0)) }))
        ModePicker(store: store, style: modeStyle).disabled(!store.bool("enabled"))
    }
    /// The note under the switch: the mode's effect, or what switching off does.
    static func footer(_ store: SettingsStore) -> String {
        store.bool("enabled") ? StudioMode.explanation(store.string("mode"))
            : L10n.text("꺼 두면 선택한 표시 방식과 관계없이 원래 공유 창이 보입니다.")
    }
}

/// Settings that only matter for the custom window explain that once.
struct CustomOnlyNote: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        if !StudioMode.customInEffect(store) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(L10n.text("이 설정은 표시 방식이 꾸민 창일 때만 적용됩니다.")).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(L10n.text("꾸민 창으로 바꾸기")) { store.update(["enabled": .bool(true), "mode": .string("custom")]) }
                    .fixedSize()
            }
        }
    }
}

// MARK: - Position, size and behavior
/// The display, the reference position, the offsets for custom and edge placements, and keeping the window on screen.
struct PositionRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        DisplayRow(store: store)
        ChoiceRow(title: L10n.text("기준 위치"), key: "placement", store: store)
        if store.string("placement") == "custom" {
            NumberRow(title: L10n.text("왼쪽에서"), key: "x", store: store)
            NumberRow(title: L10n.text("위에서"), key: "y", store: store)
        }
        if ["top", "bottom"].contains(store.string("placement")) {
            NumberRow(title: L10n.text("화면 가장자리 간격"), key: "edgeInset", store: store)
        }
        Toggle(L10n.text("화면 안에 유지"), isOn: Binding(get: { store.bool("constrainToScreen") }, set: { store.set("constrainToScreen", .bool($0)) }))
    }
    static func footer(_ store: SettingsStore) -> String? {
        if store.string("placement") == "custom" { return L10n.text("메뉴 막대와 Dock을 제외한 화면 왼쪽 위를 기준으로 합니다. 공유 창을 끌어서 옮기면 위치가 여기에 반영됩니다.") }
        if !store.bool("constrainToScreen") { return L10n.text("공유 창이 화면 밖으로 벗어나면 메뉴 막대에서 가운데로 이동을 눌러 되돌리세요.") }
        return nil
    }
}

/// Width and height.
struct SizeRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        NumberRow(title: L10n.text("너비"), key: "width", store: store)
        NumberRow(title: L10n.text("높이"), key: "height", store: store)
    }
    static var footer: String { L10n.text("크기를 바꾸면 창 모양이 직접 지정으로 바뀝니다.") }
}

/// The position and size locks. Each lock is the inverse of the key it guards: the position lock
/// (위치 잠금) is draggable off and the size lock (크기 잠금) is resizable off, so the locks need
/// no settings keys of their own.
enum WindowLock: CaseIterable {
    case position, size
    var key: String { self == .position ? "draggable" : "resizable" }
    var title: String { L10n.text(self == .position ? "위치 잠금" : "크기 잠금") }
    func isLocked(_ values: [String: ConfigValue]) -> Bool { !(values[key]?.bool ?? true) }
    func change(locked: Bool) -> [String: ConfigValue] { [key: .bool(!locked)] }
}

/// A toggle that turns a lock on or off.
struct LockToggle: View {
    let lock: WindowLock
    @ObservedObject var store: SettingsStore
    var body: some View {
        Toggle(lock.title, isOn: Binding(get: { lock.isLocked(store.values) }, set: { store.update(lock.change(locked: $0)) }))
    }
}

/// The two locks, keeping the window above other windows, and how the Stop Sharing button that a
/// double-click shows on any shape is hidden again.
struct BehaviorRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        LockToggle(lock: .position, store: store)
        LockToggle(lock: .size, store: store)
        ConfigurationToggle(title: L10n.text("다른 창 위에 표시"), key: "alwaysOnTop", store: store)
        ShrinkRows(store: store)
    }
    static var footer: String { L10n.text("공유 창의 아무 곳이나 끌어서 옮깁니다. 아무 곳이나 두 번 클릭하면 어떤 모양에서든 공유 중지 버튼이 나타나고, 버튼 밖을 다시 두 번 클릭하면 원래 모양으로 돌아갑니다. 위치나 크기를 잠가도 두 번 클릭은 작동합니다.") }
}

// MARK: - Appearance
/// The light, dark or system appearance picker.
struct ThemeRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        HStack(alignment: .top) {
            Text(L10n.text("화면 모드"))
            Spacer(minLength: 12)
            AppearanceThumbnailPicker(store: store).fixedSize()
        }
    }
}

/// The built-in shapes and the content layout.
struct ShapeRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        ShapePresetPicker(store: store)
        ChoiceRow(title: L10n.text("내용 배열"), key: "layout", store: store, segmented: true)
    }
    static var footer: String { L10n.text("창 모양을 고르면 크기와 표시 항목이 함께 바뀝니다.") }
}

/// The status dot's color, size and padding.
struct DotRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        ColorRow(title: L10n.text("상태 점 색상"), key: "dotColor", store: store)
        DotAppearanceSettingsRows(store: store)
    }
    static var footer: String { L10n.text("창 크기를 바꿔도 상태 점은 가운데에 유지됩니다.") }
}

/// Two ways to hide the Stop Sharing button that a double-click shows, on every shape.
/// "Until I hide it" stores 0; "automatically" asks for 1 to 30 seconds right below the choice.
struct ShrinkRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Picker(L10n.text("공유 중지 버튼 숨기기"), selection: Binding(get: { store.shrinksAutomatically }, set: { store.setShrinksAutomatically($0) })) {
            Text(L10n.text("직접 숨길 때까지")).tag(false)
            Text(L10n.text("자동으로")).tag(true)
        }
        .pickerStyle(.segmented)
        if store.shrinksAutomatically {
            NumberRow(title: L10n.text("숨기기 전 대기 시간"), key: ShrinkSetting.key, store: store, unit: .seconds,
                      limits: ShrinkSetting.automaticRange)
        }
    }
    /// The picker title and its two choices.
    static var titles: [String] { [L10n.text("공유 중지 버튼 숨기기"), L10n.text("직접 숨길 때까지"), L10n.text("자동으로"), L10n.text("숨기기 전 대기 시간")] }
}

/// Accent, background and text colors.
struct ColorRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        ColorRow(title: L10n.text("강조 색상"), key: "accent", store: store)
        ColorRow(title: L10n.text("배경 색상"), key: "background", store: store)
        ColorRow(title: L10n.text("글자 색상"), key: "foreground", store: store)
    }
    static var footer: String { L10n.text("강조 색상은 테두리와 상태 점에 쓰입니다.") }
}

/// Corner radius, border, font size, opacity and shadow.
struct DetailRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        NumberRow(title: L10n.text("모서리 둥글기"), key: "radius", store: store)
        NumberRow(title: L10n.text("테두리 두께"), key: "borderWidth", store: store, hint: L10n.text("0이면 테두리 없음"))
        NumberRow(title: L10n.text("글자 크기"), key: "fontSize", store: store, hint: L10n.text("0이면 시스템 기본 크기"))
        PercentRow(title: L10n.text("불투명도"), key: "opacity", store: store)
        ConfigurationToggle(title: L10n.text("그림자"), key: "shadow", store: store)
    }
}

/// What the window shows: the dot, and outside the dot layout the text and the Stop button; and the
/// Stop button's style, which also applies to the Stop in the capsule.
struct ContentRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        ConfigurationToggle(title: L10n.text("상태 점 표시"), key: "showDot", store: store)
        if store.string("layout") != "dot" {
            ConfigurationToggle(title: L10n.text("안내 문구 표시"), key: "showText", store: store)
            TextRow(title: L10n.text("안내 문구"), key: "text", store: store, placeholder: L10n.text("화면을 공유하고 있습니다"))
                .disabled(!store.bool("showText"))
            ConfigurationToggle(title: L10n.text("공유 중지 버튼 표시"), key: "showStopButton", store: store)
            TextRow(title: L10n.text("공유 중지 버튼 이름"), key: "buttonText", store: store, placeholder: L10n.text("공유 중지"))
                .disabled(!store.bool("showStopButton"))
        }
        // Every shape's Stop uses this style, the one in the capsule a double-click opens included.
        ChoiceRow(title: L10n.text("공유 중지 버튼 모양"), key: "stopStyle", store: store, segmented: true)
    }
    static func footer(_ store: SettingsStore) -> String {
        store.string("layout") == "dot" ? L10n.text("상태 점 배열에서는 상태 점만 보입니다.")
            : L10n.text("안내 문구를 비워 두면 기본 문구를 사용합니다.")
    }
}

/// The move handle's visibility, position, size and opacity.
struct HandleRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        ConfigurationToggle(title: L10n.text("이동 핸들 표시"), key: "showHandle", store: store)
        Group {
            ChoiceRow(title: L10n.text("이동 핸들 위치"), key: "handlePosition", store: store, segmented: true)
            NumberRow(title: L10n.text("이동 핸들 크기"), key: "handleSize", store: store)
            PercentRow(title: L10n.text("이동 핸들 불투명도"), key: "handleOpacity", store: store)
        }.disabled(!store.bool("showHandle"))
    }
    static func footer(_ store: SettingsStore) -> String {
        store.bool("draggable") ? L10n.text("이동 핸들을 숨겨도 공유 창의 아무 곳이나 끌어서 옮길 수 있습니다.")
            : L10n.text("위치 잠금이 켜져 있어 이동 핸들이 흐리게 표시됩니다.")
    }
}

/// The dot diameter and padding. Changing either resizes the background around the same center
/// (DotAppearanceGeometry) and makes the shape custom.
struct DotAppearanceSettingsRows: View {
    @ObservedObject var store: SettingsStore
    private var geometry: DotAppearanceGeometry {
        .init(width: store.number("width"), height: store.number("height"), x: store.number("x"), y: store.number("y"))
    }
    private var diameter: Double { store.number("dotDiameter") }
    private var padding: Double { geometry.padding(pointDiameter: diameter) }
    var body: some View {
        let limits = store.schema.numericLimits["dotDiameter", default: [2, 128]]
        let side = min(store.schema.numericLimits["width"]?.last ?? 0, store.schema.numericLimits["height"]?.last ?? 0)
        DotMetricRow(title: L10n.text("상태 점 지름"), value: diameter, range: limits[0]...limits[1], store: store, id: "dot-diameter") { value in
            apply(pointDiameter: value, padding: padding); return store.number("dotDiameter")
        }
        DotMetricRow(title: L10n.text("상태 점 여백"), value: padding, range: 0...max(0, (side - diameter) / 2), store: store, id: "dot-padding") { value in
            apply(pointDiameter: diameter, padding: value); return geometry.padding(pointDiameter: diameter)
        }
    }
    /// Writes the dot diameter and the resized square frame; a custom position moves to keep the center.
    private func apply(pointDiameter: Double, padding: Double) {
        let next = geometry.resized(pointDiameter: pointDiameter, padding: padding)
        var changes: [String: ConfigValue] = [
            "dotDiameter": .number(pointDiameter), "width": .number(next.width), "height": .number(next.height),
            "radius": .number(next.width / 2), "shape": .string("custom"), "layout": .string("dot")
        ]
        if store.string("placement") == "custom" { changes["x"] = .number(next.x); changes["y"] = .number(next.y) }
        store.update(changes)
    }
}

/// A number field with a stepper for one dot metric. Typed text is staged as a draft so quitting
/// commits it; leaving the field applies it, and an out-of-range value shows the allowed range.
/// `commit` applies a value and returns the value actually stored.
@MainActor
private struct DotMetricRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let store: SettingsStore
    let id: String
    let commit: (Double) -> Double
    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var focused: Bool
    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, text: $draft).textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.trailing).frame(width: 72)
                    .focused($focused).onSubmit(applyDraft).accessibilityLabel(title)
                Text("pt").foregroundStyle(.secondary).frame(minWidth: 16, alignment: .leading)
                Stepper(title, value: Binding(get: { value }, set: { draft = StudioNumber.text(commit(min(max($0, range.lowerBound), range.upperBound))) }),
                        in: range, step: 1).labelsHidden().fixedSize()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            }
        }
        .onAppear { draft = StudioNumber.text(value) }
        .onChange(of: value) { _, new in if !focused { draft = StudioNumber.text(new) } }
        .onChange(of: focused) { _, active in if !active { applyDraft() } }
        .onChange(of: draft) { _, text in
            guard focused else { return }
            let range = range, value = value, commit = commit
            store.stageDraft(id) { if let number = StudioNumber.parse(text), range.contains(number), number != value { _ = commit(number) } }
        }
        .onDisappear { if focused { applyDraft() } }
    }
    /// Applies the typed value, or restores the stored one and shows the allowed range.
    private func applyDraft() {
        store.clearDraft(id)
        guard let number = StudioNumber.parse(draft), range.contains(number) else {
            problem = L10n.format("%@~%@ 사이의 값을 입력하세요.", StudioNumber.text(range.lowerBound), StudioNumber.text(range.upperBound))
            draft = StudioNumber.text(value)
            return
        }
        problem = nil
        draft = StudioNumber.text(number == value ? value : commit(number))
    }
}

// MARK: - Helper and maintenance
// The checklist, diagnostics, startup options, event log, settings file, and turning off or resetting.

/// The four checklist rows: helper, permission, sharing window and Chrome Remote Desktop, each with its
/// actions, plus the refresh button and the progress of a running action.
struct HelperFactRows: View {
    enum Style { case plain, checklist }
    @ObservedObject var companion: CompanionService
    @ObservedObject var store: SettingsStore
    var style: Style = .plain
    var body: some View {
        let facts = HelperFacts(companion: companion, store: store)
        row(L10n.text("창 도우미"), facts.helper, ok: facts.helperOn, attention: facts.helperNeedsAttention) {
            if companion.canManage {
                if companion.isActive {
                    Button(L10n.text("다시 시작")) { companion.perform(.restart) }.disabled(!companion.canEnable)
                } else {
                    Button(L10n.text("켜기")) { companion.turnOn() }.disabled(!companion.canEnable)
                }
            }
        }
        row(SystemNames.pick(L10n.text("손쉬운 사용 권한"), L10n.text("기기 제어 권한")), facts.permission, ok: !facts.permissionMissing && facts.permission == L10n.text("허용됨"),
            attention: facts.permissionMissing) {
            Button(L10n.text("다시 확인")) { companion.perform(.permissions) }.disabled(!companion.canManage || companion.busy)
            Button(L10n.text("시스템 설정 열기")) {
                if facts.permission != L10n.text("허용됨") { StudioLinks.requestAccessibility(companion) } else { StudioLinks.openAccessibilitySettings() }
            }
        }
        row(L10n.text("공유 창"), facts.window, ok: facts.windowFound) { EmptyView() }
        row(L10n.text("Chrome 원격 데스크톱"), facts.crd, ok: store.host.version != nil) { EmptyView() }
        HStack {
            if companion.busy { ProgressView().controlSize(.small); Text(progressTitle).foregroundStyle(.secondary) }
            Spacer()
            Button(L10n.text("상태 새로고침")) { companion.refresh(); store.refreshHost() }.disabled(companion.scriptURL == nil || companion.busy)
        }
    }
    private var progressTitle: String {
        switch companion.busyAction {
        case .install: return L10n.text("켜는 중")
        case .restore: return L10n.text("끄는 중")
        case .restart: return L10n.text("다시 시작하는 중")
        case .permissions, .requestPermission: return SystemNames.pick(L10n.text("손쉬운 사용 권한 확인 중"), L10n.text("기기 제어 권한 확인 중"))
        case .prepare: return L10n.text("준비 중")
        default: return L10n.text("상태 확인 중")
        }
    }
    /// In the checklist the value sits under the title, so the row and its buttons fit on one line
    /// at the minimum width in English. A row that blocks operation gets an orange mark.
    @ViewBuilder private func row<Buttons: View>(_ title: String, _ value: String, ok: Bool, attention: Bool = false,
                                                 @ViewBuilder buttons: () -> Buttons) -> some View {
        if style == .checklist {
            LabeledContent {
                HStack(spacing: 8) { buttons() }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                        Text(value).font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: ok ? "checkmark.circle.fill" : attention ? "exclamationmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(ok ? Color.green : attention ? Color.orange : Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(value).foregroundStyle(.secondary)
                    buttons()
                }
            } label: { Text(title) }
        }
    }
}

/// The collapsed details: detection, process ids, window states, whether the host app was modified, and the helper's path.
struct HelperDiagnosticsRows: View {
    @ObservedObject var companion: CompanionService
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(L10n.text("자세한 정보"), isExpanded: $expanded) {
            if let status = companion.status {
                LabeledContent(L10n.text("공유 창 감지"), value: companion.agentReady ? L10n.text("준비됨") : L10n.text("확인 전"))
                if let pid = status.companionService.pid, status.companionService.running { LabeledContent(L10n.text("창 도우미 PID"), value: String(pid)) }
                if companion.agentReady && status.runtime.originalWindowDetected == true {
                    LabeledContent(L10n.text("원래 공유 창"), value: tri(status.runtime.originalHidden, L10n.text("숨김"), L10n.text("보임")))
                    LabeledContent(L10n.text("꾸민 창"), value: tri(status.runtime.visible, L10n.text("보임"), L10n.text("숨김")))
                    if let pid = status.runtime.originalPid { LabeledContent(L10n.text("Chrome 원격 데스크톱 PID"), value: String(pid)) }
                }
                LabeledContent(L10n.text("Chrome 원격 데스크톱 앱 파일"), value: status.originalBundleModifiedByCompanion ? L10n.text("수정됨") : L10n.text("수정 안 됨"))
                LabeledContent(L10n.text("창 도우미 위치")) {
                    Text(status.companionPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.trailing)
                }
            } else {
                Text(L10n.text("아직 상태를 확인하지 않았습니다.")).foregroundStyle(.secondary)
            }
        }
    }
    /// `on` for true, `off` for false, and "not checked" for nil.
    private func tri(_ value: Bool?, _ on: String, _ off: String) -> String {
        switch value { case .some(true): return on; case .some(false): return off; default: return L10n.text("확인 전") }
    }
}

/// The login item and the app's launch options.
struct StartupRows: View {
    @ObservedObject var preferences: AppPreferences
    var body: some View {
        Toggle(L10n.text("로그인할 때 설정 앱 열기"), isOn: Binding(get: { preferences.loginEnabled }, set: preferences.setLoginEnabled))
        if let problem = preferences.loginProblem {
            // Say why the toggle stayed off, with the place to approve it.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(problem).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L10n.text("시스템 설정 열기")) { preferences.openLoginSettings() }.fixedSize()
            }
        }
        Toggle(L10n.text("실행할 때 설정 창 열기"), isOn: $preferences.openSettingsAtLaunch)
        Toggle(L10n.text("실행할 때 실제 크기 미리보기 열기"), isOn: $preferences.showPreviewAtLaunch)
        Toggle(L10n.text("설정 창을 화면 가운데에 열기"), isOn: $preferences.centerAtLaunch)
    }
    static var footer: String { L10n.text("창 도우미는 로그인할 때 자동으로 시작되며, 설정 창을 닫아도 계속 작동합니다.") }
}

/// The event log switch, and showing or exporting the log file.
struct LogRows: View {
    @ObservedObject var store: SettingsStore
    @State private var errorMessage: String?
    private var supportDirectory: URL { store.repository.url.deletingLastPathComponent() }
    private var logURL: URL { supportDirectory.appendingPathComponent("logs/events.jsonl") }
    private var logExists: Bool { FileManager.default.fileExists(atPath: logURL.path) }
    var body: some View {
        ConfigurationToggle(title: L10n.text("상태와 설정 변경 기록"), key: "loggingEnabled", store: store).disabled(!store.canSave)
        LabeledContent(L10n.text("기록 파일")) {
            HStack(spacing: 8) {
                Button(L10n.text("Finder에서 보기"), action: showLogs)
                Button(L10n.text("내보내기"), action: exportLogs).disabled(!logExists)
            }
        }
        .alert(L10n.text("기록"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L10n.text("확인"), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
    static var footer: String { L10n.text("설정과 창 상태 변경 내역을 최대 1 MiB까지 기록합니다. 24시간이 지난 기록은 창 도우미가 켜져 있는 동안 자동으로 지워지며, 꺼져 있었다면 다음에 켜거나 상태를 확인하거나 끌 때 정리됩니다. 계정 정보와 직접 입력한 문구는 기록되지 않습니다.") }
    /// Shows the log in Finder, or the nearest existing folder.
    private func showLogs() {
        if logExists { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
        else { NSWorkspace.shared.open(FileManager.default.fileExists(atPath: logURL.deletingLastPathComponent().path) ? logURL.deletingLastPathComponent() : supportDirectory) }
    }
    /// Copies the log to a file the user picks; the original log file itself is refused as the destination.
    private func exportLogs() {
        guard logExists else { errorMessage = L10n.text("아직 저장된 기록이 없습니다. 기록을 켠 뒤 다시 시도하세요."); return }
        let panel = NSSavePanel()
        panel.title = L10n.text("기록 내보내기")
        panel.nameFieldStringValue = "CRDWindow-events.jsonl"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let source = logURL
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            guard destination.resolvingSymlinksInPath() != source.resolvingSymlinksInPath() else {
                errorMessage = L10n.text("원본 기록 파일과 다른 위치나 파일 이름을 선택하세요.")
                return
            }
            do { try Data(contentsOf: source).write(to: destination, options: .atomic) }
            catch { errorMessage = error.localizedDescription }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

/// The settings file path. The section title already says what the path is. The path reads from the leading
/// edge on one line (shortened in the middle, whole in its tooltip), with its buttons trailing.
struct SettingsFileRows: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        let path = store.repository.url.path(percentEncoded: false)
        HStack(spacing: 8) {
            Text(path).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                .help(path)
            Spacer(minLength: 8)
            Button(L10n.text("Finder에서 보기")) { NSWorkspace.shared.activateFileViewerSelecting([store.repository.url]) }.fixedSize()
            Button(L10n.text("다시 읽기")) { store.reload() }.fixedSize()
        }
        if let date = store.savedAt { LabeledContent(L10n.text("마지막 저장"), value: date.formatted(date: .omitted, time: .standard)) }
    }
    static var footer: String { L10n.text("설정 파일을 직접 수정하면 변경 사항을 자동으로 불러옵니다.") }
}

/// Turning the helper off and restoring the default settings, each behind a confirmation.
struct DangerRows: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var companion: CompanionService
    var body: some View {
        LabeledContent {
            // Turning off can be undone, so it is a plain bordered button; it keeps its confirmation.
            ConfirmedButton(title: L10n.text("창 도우미 끄기"), question: L10n.text("창 도우미를 끌까요?"),
                            message: L10n.text("원래 공유 창이 다시 보이고 메뉴 막대 아이콘이 사라집니다. 창 도우미를 다시 켤 때까지 설정이 적용되지 않습니다."),
                            confirm: L10n.text("끄기"),
                            disabled: !companion.canDisable, destructive: false) {
                companion.perform(.restore)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("창 도우미"))
                Text(L10n.text("창 도우미를 끄지 않고 원래 공유 창만 보려면 표시에서 공유 창 바꾸기를 끄세요.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        LabeledContent {
            ConfirmedButton(title: L10n.text("기본값으로 되돌리기"), question: L10n.text("모든 공유 창 설정을 기본값으로 되돌릴까요?"),
                            message: L10n.text("현재 설정을 같은 폴더에 백업하고 기본값으로 되돌립니다. 표시 방식은 꾸민 창으로 바뀝니다."),
                            confirm: L10n.text("기본값으로 되돌리기"), disabled: !store.canSave) { store.restoreDefaults() }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("공유 창 설정"))
                Text(L10n.text("설정 앱 시작 옵션은 그대로 유지됩니다.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
