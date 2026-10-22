import CRDSettingsCore
import AppKit
import ServiceManagement

/// The settings app's own login item. Tests replace it; the app uses SMAppService.mainApp.
struct LoginItemControl {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () throws -> Void
    static let mainApp = LoginItemControl(status: { SMAppService.mainApp.status },
                                          register: { try SMAppService.mainApp.register() },
                                          unregister: { try SMAppService.mainApp.unregister() })
}

/// The app's own launch preferences in UserDefaults and its login item state.
@MainActor
final class AppPreferences: ObservableObject {
    @Published var openSettingsAtLaunch: Bool { didSet { defaults.set(openSettingsAtLaunch, forKey: "openSettingsAtLaunch") } }
    @Published var showPreviewAtLaunch: Bool { didSet { defaults.set(showPreviewAtLaunch, forKey: "showPreviewAtLaunch") } }
    @Published var centerAtLaunch: Bool { didSet { defaults.set(centerAtLaunch, forKey: "centerAtLaunch") } }
    @Published private(set) var loginEnabled = false
    @Published var loginError: String?
    /// True while the login item waits for approval in System Settings.
    @Published private(set) var loginNeedsApproval = false
    private let defaults: UserDefaults
    private let readsLoginItem: Bool
    private let loginItem: LoginItemControl
    init(defaults: UserDefaults = .standard, readsLoginItem: Bool = true, loginItem: LoginItemControl = .mainApp) {
        self.readsLoginItem = readsLoginItem
        self.loginItem = loginItem
        self.defaults = defaults
        defaults.register(defaults: ["openSettingsAtLaunch": true, "showPreviewAtLaunch": false, "centerAtLaunch": true])
        openSettingsAtLaunch = defaults.bool(forKey: "openSettingsAtLaunch")
        showPreviewAtLaunch = defaults.bool(forKey: "showPreviewAtLaunch")
        centerAtLaunch = defaults.bool(forKey: "centerAtLaunch")
        refreshLoginStatus()
    }
    /// Reads the login item status; clears the last error once the item is enabled.
    func refreshLoginStatus() {
        guard readsLoginItem else { return }
        let status = loginItem.status()
        loginEnabled = status == .enabled
        loginNeedsApproval = status == .requiresApproval
        if loginEnabled { loginError = nil } // Approved since the last attempt.
    }
    /// Registers or unregisters the login item, and keeps a readable error when that fails.
    func setLoginEnabled(_ enabled: Bool) {
        guard readsLoginItem else { return }
        loginError = nil // A new attempt replaces the old error.
        do {
            if enabled { try loginItem.register() } else { try loginItem.unregister() }
            refreshLoginStatus()
        } catch {
            loginError = L10n.format("로그인 항목을 바꾸지 못했습니다. %@", error.localizedDescription)
            refreshLoginStatus()
        }
    }
    /// What StartupRows shows under the login toggle, nil when nothing is wrong.
    var loginProblem: String? {
        loginError ?? (loginNeedsApproval ? L10n.text("시스템 설정 > 일반 > 로그인 항목 및 확장 프로그램에서 설정 앱을 허용하세요.") : nil)
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
