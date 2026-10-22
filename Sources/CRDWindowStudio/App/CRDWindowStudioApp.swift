import CRDSettingsCore
import AppKit
import SwiftUI

/// The settings app: one settings window, the menu commands, and the full-size preview window.
struct CRDWindowStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @StateObject private var store: SettingsStore
    @StateObject private var preferences: AppPreferences
    @StateObject private var companion: CompanionService
    @StateObject private var navigation = SettingsNavigation()
    private let preview: PreviewWindowController
    init() {
        let preferences = AppPreferences()
        let store = SettingsStore(shrinkMemory: .standard)
        _store = StateObject(wrappedValue: store)
        _preferences = StateObject(wrappedValue: preferences)
        _companion = StateObject(wrappedValue: CompanionService())
        preview = PreviewWindowController(store: store)
    }
    var body: some Scene {
        Window(L10n.text("설정 창"), id: "settings") {
            SettingsWindow(environment: SettingsEnvironment(store: store, preferences: preferences, companion: companion,
                                                            openPreview: preview.show, navigation: navigation),
                           appDelegate: delegate)
        }
        .defaultSize(width: 820, height: 740)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("설정 다시 읽기")) { store.reload() }.keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("설정 창 열기")) { delegate.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu(L10n.text("미리보기")) {
                Button(L10n.text("실제 크기로 보기")) { preview.show() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
            CommandGroup(before: .sidebar) {
                PageCommands(navigation: navigation)
            }
        }
    }
}

/// Activates the app at launch when the settings window should open, and reopens it on request.
@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    var settingsOpener: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if Self.shouldActivateAtLaunch(defaults: .standard, arguments: ProcessInfo.processInfo.arguments) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    /// True when `--show-settings` is passed, or the user chose to open settings or the preview at launch.
    static func shouldActivateAtLaunch(defaults: UserDefaults, arguments: [String]) -> Bool {
        arguments.contains("--show-settings") || (defaults.object(forKey: "openSettingsAtLaunch") as? Bool ?? true)
            || defaults.bool(forKey: "showPreviewAtLaunch")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A visible preview must not suppress an explicit settings request.
        openSettings()
        return true
    }
    /// Shows the settings window, restoring it from the Dock, or asks SwiftUI to create it.
    /// Marks the request as explicit, so a pending hide at launch does not undo it.
    func openSettings() {
        MainWindowReader.markExplicitPresentation()
        NSApp.unhide(nil)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "CRDWindowStudioSettings" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else { settingsOpener?() }
        NSApp.activate(ignoringOtherApps: true)
    }
}
