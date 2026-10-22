import CRDSettingsCore
import Foundation

/// The JSON that `companionctl.py status` prints: the install state, the helper and host services,
/// the helper's runtime report, and any error codes.
struct CompanionStatus: Decodable, Sendable {
    /// A launchd service as the controller sees it.
    struct ServiceState: Decodable, Sendable {
        let loaded: Bool
        let running: Bool
        let pid: Int?
    }
    /// What the running helper last reported. Optional fields may be absent from older helpers.
    struct RuntimeState: Decodable, Sendable {
        let confirmed: Bool
        let agentReady: Bool?
        let observerReady: Bool?
        let backendKind: String?
        let originalWindowDetected: Bool?
        let visible: Bool?
        let originalHidden: Bool?
        let originalPid: Int?
        let fixture: Bool?
        let pid: Int?
        let mode: String?
        let accessibility: Bool?
        let stopActionAvailable: Bool?
        let enabled: Bool?
        let effectiveMode: String?
        let detectionReason: String?
        /// A pending restoration alone is normal; blocked means it cannot proceed.
        let restorationBlocked: Bool?
        let restorationPending: Bool?
        /// false: the helper did not acknowledge the last refresh, so the other runtime values are cached.
        let refreshConfirmed: Bool?
    }
    let state: String
    let companionPath: String
    let companionService: ServiceState
    let originalService: ServiceState
    let runtime: RuntimeState
    let originalBundleModifiedByCompanion: Bool
    let error: String?
    let cleanupError: String?
    let errorCode: String?
    let cleanupErrorCode: String?
}

/// A process boundary to the bundled window-helper CLI. Helper readiness and
/// original-window detection are deliberately distinct observable states.
@MainActor
final class CompanionService: ObservableObject {
    enum Action: String, Sendable {
        case status, prepare, permissions, install, restore, restart
        /// Asks the helper to show the macOS Accessibility request. Only the
        /// permission row's main action uses it; the plain re-check never prompts.
        case requestPermission
        var arguments: [String] { self == .requestPermission ? ["permissions", "--prompt"] : [rawValue] }
        /// Checks that do not change the helper's state.
        var isCheck: Bool { [.status, .permissions, .requestPermission].contains(self) }
    }
    @Published private(set) var status: CompanionStatus?
    @Published private(set) var busyAction: Action?
    @Published private(set) var permissionDescription: String?
    /// Result of the last explicit permission check (nil until checked).
    @Published private(set) var accessibilityAllowed: Bool?
    @Published var errorMessage: String?
    @Published private(set) var errorCode: String?
    /// Counts explicit actions (everything but a status refresh). A new
    /// attempt may alert again with the same error; a passive refresh may not.
    @Published private(set) var attempt = 0
    /// The problem of one attempt for the error alert: the attempt and its codes.
    struct AlertKey: Equatable {
        let attempt: Int
        let codes: Set<String>
        /// Dismissing again within one attempt remembers every code seen so far.
        func merged(with dismissed: AlertKey?) -> AlertKey {
            guard let dismissed, dismissed.attempt == attempt else { return self }
            return AlertKey(attempt: attempt, codes: codes.union(dismissed.codes))
        }
    }
    /// The current problem as an alert key; nil when there is no error.
    var alertKey: AlertKey? {
        guard errorCode != nil || errorMessage != nil else { return nil }
        return AlertKey(attempt: attempt, codes: Set([errorCode ?? "operation_failed", status?.cleanupErrorCode].compactMap { $0 }))
    }
    /// A new explicit attempt alerts again; a refresh repeating dismissed codes does not.
    static func shouldAlert(_ key: AlertKey?, dismissed: AlertKey?) -> Bool {
        guard let key else { return false }
        guard let dismissed, dismissed.attempt == key.attempt else { return true }
        return !key.codes.isSubset(of: dismissed.codes)
    }
    let scriptURL: URL?
    let runtimeIncluded: Bool
    private let execute: @Sendable (URL, Action) throws -> Data

    /// Finds `companionctl.py` and the helper binary in the app's Backend resources.
    /// `execute` runs one controller command; tests and snapshots replace it.
    init(bundle: Bundle = .main, script: URL? = nil, includesRuntime: Bool? = nil,
         execute: @escaping @Sendable (URL, Action) throws -> Data = { try CompanionService.executeCommand(script: $0, action: $1) }) {
        let backend = bundle.resourceURL?.appendingPathComponent("Backend", isDirectory: true)
        scriptURL = script ?? (backend?.appendingPathComponent("companionctl.py")).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        runtimeIncluded = includesRuntime ?? (backend.map { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("OverlayAgent").path) } ?? false)
        self.execute = execute
    }
    // MARK: - Derived state
    // What the status allows and how it reads.
    var canManage: Bool { scriptURL != nil && runtimeIncluded }
    var busy: Bool { busyAction != nil }
    var isActive: Bool { status?.state == "active" }
    /// True when the helper service runs and has confirmed that its window agent and observer are ready.
    var agentReady: Bool {
        guard let status else { return false }
        return status.companionService.running && status.runtime.confirmed
            && status.runtime.agentReady == true && status.runtime.observerReady == true
            && status.runtime.backendKind == "accessibility-overlay"
    }
    /// The original sharing window could not be shown again; only turning off (a restoration retry) helps.
    var restorationBlocked: Bool { status?.runtime.restorationBlocked == true }
    /// The runtime values were not freshly acknowledged. Absent on older helpers.
    var refreshUnconfirmed: Bool { status?.runtime.refreshConfirmed == false }
    /// Turn On is possible from an active, off, prepared, restored or rolled-back state, unless restoration is blocked.
    var canEnable: Bool {
        canManage && !busy && !restorationBlocked && ["active", "not_installed", "prepared", "restored", "rolled_back"].contains(status?.state ?? "")
    }
    /// Turn Off is possible while the helper is active, switching, failed to clean up, or still loaded.
    var canDisable: Bool {
        canManage && !busy && (["active", "switching", "cleanup_failed", "rollback_failed"].contains(status?.state ?? "") ||
                              status?.companionService.loaded == true)
    }
    var summary: String { L10n.text(summaryKey) }
    /// The localization key of the one-word helper state.
    var summaryKey: String {
        guard canManage else { return "창 도우미가 포함되지 않음" }
        guard let status else { return "확인 전" }
        if isActive && agentReady { return "켜짐" }
        switch status.state {
        case "active": return "준비되지 않음"
        case "switching": return "시작 중"
        case "not_installed", "prepared", "restored": return "꺼짐"
        case "rolled_back": return "시작하지 못함"
        case "cleanup_failed", "rollback_failed": return "완전히 꺼지지 않음"
        default: return status.state
        }
    }
    /// Whether the helper has found the original sharing window.
    var windowDetectionDescription: String {
        guard agentReady else { return isActive ? L10n.text("확인 전") : L10n.text("창 도우미 꺼짐") }
        switch status?.runtime.originalWindowDetected {
        case .some(true): return L10n.text("감지됨")
        case .some(false): return L10n.text("원격 연결 대기 중")
        default: return L10n.text("확인 전")
        }
    }
    // MARK: - Actions
    func refresh() { perform(.status) }
    /// The helper is off and nothing says whether the permission is granted (no check
    /// this session and no coded permission failure). Turning on then asks macOS first.
    var permissionUnknownBeforeInstall: Bool {
        guard let status, ["not_installed", "prepared", "restored"].contains(status.state) else { return false }
        return accessibilityAllowed == nil && !StudioStatus.permissionMissing(self)
    }
    /// Turns the helper on. With the permission unknown, the permission request (`permissions --prompt`)
    /// runs first, and `install` follows only after it reports the permission granted. A denial
    /// installs nothing; the status then offers the permission action (the existing recovery).
    /// Every other state installs directly.
    func turnOn() {
        guard permissionUnknownBeforeInstall else { perform(.install); return }
        perform(.requestPermission) { [weak self] in
            guard let self, self.accessibilityAllowed == true else { return }
            self.perform(.install)
        }
    }
    /// Runs one controller action off the main thread, then refreshes the status, since a failed
    /// change can still have stopped or archived the helper. Errors from both are combined.
    /// `completion` runs on the main actor once the action and the status refresh
    /// finish, or right away when the action cannot start.
    func perform(_ action: Action, completion: (@MainActor () -> Void)? = nil) {
        guard !busy, let scriptURL, action == .status || canManage else { completion?(); return }
        busyAction = action
        if action != .status { attempt += 1 }
        errorMessage = nil
        errorCode = nil
        let execute = self.execute
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var data: Data?, failure: String?, failureCode: String?, permissions: String?, allowed: Bool?
                do {
                    data = try execute(scriptURL, action)
                    if action == .permissions || action == .requestPermission,
                       let data,
                       let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let access: String
                        allowed = object["accessibility"] as? Bool
                        switch allowed {
                        case .some(true): access = L10n.text("허용됨")
                        case .some(false): access = L10n.text("허용 필요")
                        default: access = L10n.text("확인 전")
                        }
                        permissions = SystemNames.pick(L10n.format("손쉬운 사용 권한: %@", access), L10n.format("기기 제어 권한: %@", access))
                    }
                } catch {
                    failure = error.localizedDescription
                    failureCode = BoundedProcess.errorCode(for: error) ?? "operation_failed"
                }
                // A failed mutation can still have stopped/archived the helper.
                do {
                    let statusData = action == .status ? data : try execute(scriptURL, .status)
                    let status = try statusData.map { try JSONDecoder().decode(CompanionStatus.self, from: $0) }
                    return (status, permissions, failure, failureCode, allowed)
                } catch {
                    return (nil, permissions, [failure, error.localizedDescription].compactMap { $0 }.joined(separator: "\n"),
                            failureCode ?? BoundedProcess.errorCode(for: error) ?? (error is DecodingError ? "invalid_data" : "operation_failed"), allowed)
                }
            }.value
            busyAction = nil
            status = result.0 // Never retain stale readiness when the refresh fails.
            if let permissions = result.1 { permissionDescription = permissions; accessibilityAllowed = result.4 }
            var details = result.2 ?? ""
            for detail in [result.0?.error, result.0?.cleanupError].compactMap({ $0 }) where !details.contains(detail) {
                details += (details.isEmpty ? "" : "\n") + detail
            }
            errorMessage = details.isEmpty ? nil : details
            errorCode = result.3 ?? result.0?.errorCode ?? result.0?.cleanupErrorCode
            completion?()
        }
    }
    /// The arguments for `python3`: the script path, then the action's arguments.
    nonisolated static func commandArguments(script: URL, action: Action) -> [String] { [script.path] + action.arguments }
    /// Runs the controller with the system Python and an 80-second limit.
    nonisolated static func executeCommand(script: URL, action: Action) throws -> Data {
        try BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                               arguments: commandArguments(script: script, action: action), timeout: 80)
    }
}
