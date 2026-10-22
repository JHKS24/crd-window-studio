import AppKit
import CRDSettingsCore
import SwiftUI

/// The four settings pages in task order.
enum SettingsPage: String, CaseIterable, Identifiable {
    case display, position, appearance, helper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .display: return L10n.text("표시")
        case .position: return L10n.text("위치와 크기")
        case .appearance: return L10n.text("모양")
        case .helper: return L10n.text("문제 해결")
        }
    }
    var symbol: String {
        switch self {
        case .display: return "eye"
        case .position: return "arrow.up.and.down.and.arrow.left.and.right"
        case .appearance: return "paintpalette"
        case .helper: return "stethoscope"
        }
    }
}

/// Page selection shared by the window and the View menu's page commands.
@MainActor final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage
    init(page: SettingsPage = .display) { self.page = page }
}

/// The stores and actions every settings page uses.
struct SettingsEnvironment {
    let store: SettingsStore
    let preferences: AppPreferences
    let companion: CompanionService
    let openPreview: () -> Void
    let navigation: SettingsNavigation
}

/// View menu commands that switch pages with Command-1 to Command-4.
struct PageCommands: View {
    @ObservedObject var navigation: SettingsNavigation
    var body: some View {
        ForEach(Array(SettingsPage.allCases.enumerated()), id: \.element) { index, page in
            Button(page.title) { navigation.page = page }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        }
        Divider()
    }
}

/// Window behavior: placement at launch, refresh on activation, alerts.
struct SettingsWindow: View {
    let environment: SettingsEnvironment
    let appDelegate: StudioAppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var started = false
    var body: some View {
        SettingsContent(environment: environment)
            .background(MainWindowReader(center: environment.preferences.centerAtLaunch,
                                         showAtLaunch: environment.preferences.openSettingsAtLaunch || CommandLine.arguments.contains("--show-settings")))
            .onAppear {
                appDelegate.settingsOpener = { openWindow(id: "settings") }
                guard !started else { return }
                started = true
                environment.companion.refresh()
                // Do not wait for an activation notification that may have come before this view.
                environment.store.refreshHost()
                if environment.preferences.showPreviewAtLaunch { environment.openPreview() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                environment.preferences.refreshLoginStatus()
                environment.companion.refresh()
                environment.store.refreshHost()
            }
    }
}

/// The page layout plus the banner and alerts every page shares. Snapshots render this directly.
struct SettingsContent: View {
    let environment: SettingsEnvironment
    @ObservedObject var store: SettingsStore
    init(environment: SettingsEnvironment) { self.environment = environment; store = environment.store }
    var body: some View {
        VStack(spacing: 0) {
            if let problem = store.loadError { ConfigProblemBanner(store: store, problem: problem) }
            SettingsRoot(env: environment)
        }
        .companionErrorAlert(environment.companion)
        // A load problem has its banner; the alert is only for failed saves and edits.
        .background(EmptyView().alert(L10n.text("설정을 저장하지 못했습니다"),
                                      isPresented: Binding(get: { store.errorMessage != nil && store.loadError == nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(L10n.text("확인"), role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") })
    }
}

/// An unreadable settings file stops saving until the user recreates it
/// with a backup; a file that disappeared keeps the last values until it returns.
struct ConfigProblemBanner: View {
    @ObservedObject var store: SettingsStore
    let problem: SettingsStore.LoadError
    @State private var confirming = false
    var body: some View {
        let invalid = problem != .missing
        // The buttons sit centered on the two-line text.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20)).foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(invalid ? L10n.text("설정 파일을 읽을 수 없습니다") : L10n.text("설정 파일을 찾을 수 없습니다")).font(.headline)
                Text(invalid ? L10n.text("기존 파일을 보존하기 위해 저장을 멈췄습니다. 현재 파일을 백업한 뒤 기본값으로 다시 만들 수 있습니다.")
                             : L10n.text("현재 설정은 그대로 유지됩니다. 파일을 복원한 뒤 설정 다시 읽기를 누르세요."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button(L10n.text("Finder에서 보기")) { reveal() }
                if invalid {
                    Button(L10n.text("백업하고 다시 만들기")) { confirming = true }.buttonStyle(.prominent).fixedSize()
                } else {
                    Button(L10n.text("설정 다시 읽기")) { store.reload() }.buttonStyle(.prominent).fixedSize()
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .confirmationDialog(L10n.text("설정 파일을 다시 만들까요?"), isPresented: $confirming) {
            Button(L10n.text("백업하고 다시 만들기")) { store.recreateWithBackup() }
            Button(L10n.text("취소"), role: .cancel) {}
        } message: {
            Text(L10n.text("현재 파일을 같은 폴더에 백업한 뒤 기본값으로 다시 만듭니다. 표시 방식은 꾸민 창으로 바뀝니다."))
        }
    }
    /// Shows the settings file in Finder, or its folder when the file is missing.
    private func reveal() {
        let url = store.repository.url
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
    }
}

extension View {
    /// Helper command failures: one plain title, the coded problem as the message,
    /// and the controller's diagnostic text behind a copy button.
    func companionErrorAlert(_ companion: CompanionService) -> some View {
        modifier(CompanionErrorAlert(companion: companion))
    }
}

private struct CompanionErrorAlert: ViewModifier {
    @ObservedObject var companion: CompanionService
    /// A receipt error comes back with every status refresh; show each problem
    /// once per explicit attempt.
    @State private var dismissed: CompanionService.AlertKey?
    private func dismiss() { dismissed = companion.alertKey?.merged(with: dismissed) ?? dismissed }
    func body(content: Content) -> some View {
        content.alert(L10n.text("창 도우미 작업을 완료하지 못했습니다"),
                      isPresented: Binding(get: { CompanionService.shouldAlert(companion.alertKey, dismissed: dismissed) }, set: { if !$0 { dismiss() } })) {
            Button(L10n.text("확인"), role: .cancel) { dismiss() }
            if let details = companion.errorMessage, !details.isEmpty {
                Button(L10n.text("자세한 내용 복사")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(details, forType: .string)
                    dismiss()
                }
            }
        } message: { Text(HelperDiagnostic.alertText(companion)) }
    }
}
