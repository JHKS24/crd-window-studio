import CRDSettingsCore
import SwiftUI

/// Four pages in task order: Display, Position and Size, Appearance, Helper and
/// Troubleshooting. The status sits at the bottom of the sidebar on every page but
/// Display, which shows the same status at its top; the live preview is a
/// fixed pane above the two editing pages and is hidden, with a note, whenever the
/// custom window is not in use.
struct SettingsRoot: View {
    let env: SettingsEnvironment
    @ObservedObject var navigation: SettingsNavigation
    init(env: SettingsEnvironment) { self.env = env; navigation = env.navigation }
    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: Binding(get: { navigation.page }, set: { if let page = $0 { navigation.page = page } })) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) { if navigation.page != .display { SidebarStatus(env: env) } }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            Group {
                switch navigation.page {
                case .display: DisplayPage(env: env)
                case .position: PositionPage(env: env)
                case .appearance: AppearancePage(env: env)
                case .helper: HelperPage(env: env)
                }
            }
            .frame(minWidth: 440)
        }
        .frame(minWidth: 660, minHeight: 500)
    }
}

/// Always-visible status. A click opens the helper page when something needs attention.
private struct SidebarStatus: View {
    let env: SettingsEnvironment
    @ObservedObject var companion: CompanionService
    @ObservedObject var store: SettingsStore
    init(env: SettingsEnvironment) { self.env = env; companion = env.companion; store = env.store }
    var body: some View {
        let status = StudioStatus.make(companion: companion, store: store)
        Button { env.navigation.page = status.needsAttention ? .helper : .display } label: {
            HStack(spacing: 8) {
                Image(systemName: status.symbol).foregroundStyle(status.tint).font(.system(size: 15)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(StudioMode.title(store.bool("enabled") ? store.string("mode") : "original")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .help(status.detail)
        .accessibilityLabel(L10n.format("상태: %@", status.title))
        .accessibilityHint(status.detail)
    }
}

/// The Display page: the status, the main switch, the display mode and shortcuts to the custom window pages.
private struct DisplayPage: View {
    let env: SettingsEnvironment
    @ObservedObject var store: SettingsStore
    init(env: SettingsEnvironment) { self.env = env; store = env.store }
    var body: some View {
        Form {
            Section { StatusSummaryRow(companion: env.companion, store: store) }
            Section {
                Toggle(L10n.text("공유 창 바꾸기"), isOn: Binding(get: { store.bool("enabled") }, set: { store.set("enabled", .bool($0)) }))
            } footer: { if !store.bool("enabled") { FormFooter(SharingSwitchRows.footer(store)) } }
                .disabled(!store.canSave)
            Section {
                // One row per mode, the radio mark on the leading edge, the whole row clickable.
                ForEach(StudioMode.order, id: \.self) { ModeRadioRow(id: $0, store: store) }
            } header: { Text(L10n.text("표시 방식")) }
                .disabled(!store.bool("enabled") || !store.canSave)
            if StudioMode.customInEffect(store) {
                Section {
                    LabeledContent(L10n.text("꾸민 창")) {
                        HStack(spacing: 8) {
                            Button(L10n.text("위치와 크기")) { env.navigation.page = .position }
                            Button(L10n.text("모양")) { env.navigation.page = .appearance }
                            Button(L10n.text("실제 크기로 보기"), action: env.openPreview)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.text("표시"))
    }
}

/// The Position and Size page: the live preview over the position, size and behavior settings.
private struct PositionPage: View {
    let env: SettingsEnvironment
    @ObservedObject var store: SettingsStore
    init(env: SettingsEnvironment) { self.env = env; store = env.store }
    var body: some View {
        CompactPreviewLayout { compact in
            if StudioMode.customInEffect(store) { PreviewPane(store: store, openPreview: env.openPreview, compact: compact) }
            Form {
                if !StudioMode.customInEffect(store) { Section { CustomOnlyNote(store: store) } }
                Section {
                    PositionRows(store: store)
                } header: { Text(L10n.text("위치")) } footer: { if let text = PositionRows.footer(store) { FormFooter(text) } }
                Section { SizeRows(store: store) } header: { Text(L10n.text("크기")) } footer: { FormFooter(SizeRows.footer) }
                Section { BehaviorRows(store: store) } header: { Text(L10n.text("동작")) } footer: { FormFooter(BehaviorRows.footer) }
            }
            .formStyle(.grouped)
            // Nothing can be saved until the settings file is readable again.
            .disabled(!store.canSave)
        }
        .navigationTitle(L10n.text("위치와 크기"))
    }
}

/// The Appearance page: the live preview over shape, presets, status dot, content, colors, border and handle.
/// The status dot section shows only for the dot layout, and the handle section only for the others.
private struct AppearancePage: View {
    let env: SettingsEnvironment
    @ObservedObject var store: SettingsStore
    init(env: SettingsEnvironment) { self.env = env; store = env.store }
    var body: some View {
        let dot = store.string("layout") == "dot"
        CompactPreviewLayout { compact in
            if StudioMode.customInEffect(store) { PreviewPane(store: store, openPreview: env.openPreview, compact: compact) }
            Form {
                if !StudioMode.customInEffect(store) { Section { CustomOnlyNote(store: store) } }
                Section {
                    ShapeRows(store: store)
                } header: { Text(L10n.text("창 모양")) } footer: { FormFooter(ShapeRows.footer) }
                Section { PresetRows(store: store, presets: store.presets) } header: { Text(L10n.text("프리셋")) } footer: { FormFooter(PresetRows.footer) }
                if dot {
                    Section { DotRows(store: store) } header: { Text(L10n.text("상태 점")) } footer: { FormFooter(DotRows.footer) }
                }
                Section { ContentRows(store: store) } header: { Text(L10n.text("표시 항목")) } footer: { FormFooter(ContentRows.footer(store)) }
                Section {
                    ThemeRows(store: store)
                    ColorRows(store: store)
                } header: { Text(L10n.text("색상")) } footer: { FormFooter(ColorRows.footer) }
                Section { DetailRows(store: store) } header: { Text(L10n.text("테두리와 글자")) }
                if !dot {
                    Section { HandleRows(store: store) } header: { Text(L10n.text("이동 핸들")) } footer: { FormFooter(HandleRows.footer(store)) }
                }
            }
            .formStyle(.grouped)
            .disabled(!store.canSave)
        }
        .navigationTitle(L10n.text("모양"))
    }
}

/// The Helper and Troubleshooting page: the checklist, diagnostics, startup, log, settings file and reset.
private struct HelperPage: View {
    let env: SettingsEnvironment
    var body: some View {
        Form {
            Section {
                HelperFactRows(companion: env.companion, store: env.store, style: .checklist)
            } header: { Text(L10n.text("점검")) } footer: { FormFooter(L10n.text("네 항목이 모두 준비되면 원격 연결 중에 공유 창 설정이 적용됩니다.")) }
            Section { HelperDiagnosticsRows(companion: env.companion) }
            Section { StartupRows(preferences: env.preferences) } header: { Text(L10n.text("설정 앱 시작")) } footer: { FormFooter(StartupRows.footer) }
            Section { LogRows(store: env.store) } header: { Text(L10n.text("기록")) } footer: { FormFooter(LogRows.footer) }
            Section { SettingsFileRows(store: env.store) } header: { Text(L10n.text("설정 파일")) } footer: { FormFooter(SettingsFileRows.footer) }
            Section { DangerRows(store: env.store, companion: env.companion) } header: { Text(L10n.text("끄기와 초기화")) }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.text("문제 해결"))
    }
}

/// The editing pages stack the preview over the form; in a short window the preview
/// gets a compact canvas so more of the form stays visible.
private struct CompactPreviewLayout<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) { content(geometry.size.height < 600) }
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// Section notes read as secondary text from the leading edge, like System Settings.
private struct FormFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
