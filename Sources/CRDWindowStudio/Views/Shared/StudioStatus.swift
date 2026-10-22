import AppKit
import CRDSettingsCore
import SwiftUI

/// One answer to "does it work right now?" built from the helper status, the
/// host inspection and the saved mode. Every page shows this same model.
struct StudioStatus: Equatable {
    enum Kind: Equatable { case checking, busy, notIncluded, crdMissing, helperOff, permissionNeeded, attention, savingPaused, paused, waiting, working }
    enum Action: Equatable { case turnOnHelper, openAccessibility, restartHelper, enableSettings, retryTurnOff, refreshStatus }
    let kind: Kind
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let action: Action?

    /// The title of the status's main action button.
    var actionTitle: String? {
        switch action {
        case .turnOnHelper: return L10n.text("창 도우미 켜기")
        case .openAccessibility: return SystemNames.pick(L10n.text("손쉬운 사용 설정 열기"), L10n.text("기기 제어 설정 열기"))
        case .restartHelper: return L10n.text("창 도우미 다시 시작")
        case .enableSettings: return L10n.text("공유 창 바꾸기 켜기")
        case .retryTurnOff: return L10n.text("창 도우미 끄기 다시 시도")
        case .refreshStatus: return L10n.text("상태 새로고침")
        case nil: return nil
        }
    }
    var needsAttention: Bool { [.crdMissing, .helperOff, .permissionNeeded, .attention].contains(kind) }

    /// Builds the status. The checks run in priority order: helper not included, host not yet checked,
    /// host missing, an action running, no status yet, restoration needed, permission missing,
    /// helper off or failed to start, unconfirmed refresh, not ready, saving paused, switched off,
    /// then working or waiting for a remote session.
    @MainActor static func make(companion: CompanionService, store: SettingsStore) -> Self {
        if !companion.canManage {
            return .init(kind: .notIncluded, title: L10n.text("창 도우미가 포함되지 않음"),
                         detail: L10n.text("이 앱에는 창 도우미가 포함되어 있지 않아 설정 변경과 미리보기만 할 수 있습니다."),
                         symbol: "info.circle.fill", tint: .secondary, action: nil)
        }
        guard store.hostChecked else {
            // Unchecked is not missing; reuse the checking presentation.
            return .init(kind: .checking, title: L10n.text("상태 확인 중"), detail: L10n.text("잠시만 기다려 주세요."),
                         symbol: "hourglass", tint: .secondary, action: nil)
        }
        if store.host.version == nil {
            return .init(kind: .crdMissing, title: L10n.text("Chrome 원격 데스크톱을 찾을 수 없음"),
                         detail: L10n.text("Chrome 원격 데스크톱을 먼저 설치하세요. 설정은 미리 바꿔 둘 수 있습니다."),
                         symbol: "questionmark.circle.fill", tint: .orange, action: nil)
        }
        if let busy = companion.busyAction, !busy.isCheck {
            let title: String
            switch busy {
            case .restore: title = L10n.text("창 도우미를 끄는 중")
            case .restart: title = L10n.text("창 도우미를 다시 시작하는 중")
            default: title = L10n.text("창 도우미를 켜는 중")
            }
            return .init(kind: .busy, title: title, detail: L10n.text("잠시만 기다려 주세요."), symbol: "hourglass", tint: .secondary, action: nil)
        }
        guard let status = companion.status else {
            return .init(kind: .checking, title: L10n.text("상태 확인 중"), detail: L10n.text("잠시만 기다려 주세요."),
                         symbol: "hourglass", tint: .secondary, action: nil)
        }
        // Restoration comes first. Turning off runs the restoration-only retry;
        // turning on or restarting is never offered as recovery.
        if companion.restorationBlocked || ["cleanup_failed", "rollback_failed"].contains(status.state) {
            return restorationNeeded
        }
        // A helper that is off or rolled back for want of permission is
        // guided to the permission request, not to another failing turn-on.
        // cleanup_failed keeps its own recovery text below.
        if ["not_installed", "prepared", "restored", "rolled_back"].contains(status.state) && permissionMissing(companion) {
            return .init(kind: .permissionNeeded, title: SystemNames.pick(L10n.text("손쉬운 사용 권한 필요"), L10n.text("기기 제어 권한 필요")),
                         detail: SystemNames.pick(L10n.text("시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 CRD Window Host를 켜세요."), L10n.text("시스템 설정 > 개인정보 보호 및 보안 > 기기 제어 및 데이터 접근에서 CRD Window Host를 켜세요.")),
                         symbol: "hand.raised.circle.fill", tint: .orange, action: .openAccessibility)
        }
        switch status.state {
        case "not_installed", "prepared", "restored":
            return .init(kind: .helperOff, title: L10n.text("창 도우미 꺼짐"),
                         detail: L10n.text("창 도우미를 켜야 공유 창에 설정이 적용됩니다."),
                         symbol: "power.circle.fill", tint: .secondary, action: .turnOnHelper)
        case "rolled_back":
            return .init(kind: .attention, title: L10n.text("창 도우미를 시작하지 못함"),
                         detail: SystemNames.pick(L10n.text("창 도우미를 시작하지 못해 다시 껐습니다. 손쉬운 사용 권한을 확인한 뒤 다시 켜세요."), L10n.text("창 도우미를 시작하지 못해 다시 껐습니다. 기기 제어 권한을 확인한 뒤 다시 켜세요.")),
                         symbol: "exclamationmark.triangle.fill", tint: .orange, action: .turnOnHelper)
        case "switching":
            return .init(kind: .busy, title: L10n.text("창 도우미를 켜는 중"), detail: L10n.text("잠시만 기다려 주세요."),
                         symbol: "hourglass", tint: .secondary, action: nil)
        default: break
        }
        // Cached runtime values are not a result; ask for a fresh refresh first.
        if companion.refreshUnconfirmed {
            return .init(kind: .attention, title: L10n.text("창 도우미 상태 확인 필요"),
                         detail: L10n.text("창 도우미가 상태 확인에 응답하지 않았습니다. 상태 새로고침을 다시 누르세요."),
                         symbol: "arrow.clockwise.circle.fill", tint: .orange, action: .refreshStatus)
        }
        if permissionMissing(companion) {
            return .init(kind: .permissionNeeded, title: SystemNames.pick(L10n.text("손쉬운 사용 권한 필요"), L10n.text("기기 제어 권한 필요")),
                         detail: SystemNames.pick(L10n.text("시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 CRD Window Host를 켜세요."), L10n.text("시스템 설정 > 개인정보 보호 및 보안 > 기기 제어 및 데이터 접근에서 CRD Window Host를 켜세요.")),
                         symbol: "hand.raised.circle.fill", tint: .orange, action: .openAccessibility)
        }
        guard companion.agentReady else {
            return .init(kind: .attention, title: L10n.text("창 도우미가 응답하지 않음"),
                         detail: L10n.text("창 도우미를 다시 시작해 보세요."),
                         symbol: "exclamationmark.triangle.fill", tint: .orange, action: .restartHelper)
        }
        let found = status.runtime.originalWindowDetected == true
        // Under the settings-file banner nothing can be saved. The helper keeps working with the
        // last settings it read, so this is not a helper problem; the banner holds the actions.
        if store.loadError != nil {
            return .init(kind: .savingPaused, title: L10n.text("설정 저장 멈춤"),
                         detail: L10n.text("창 도우미는 마지막으로 읽은 설정으로 계속 작동합니다."),
                         symbol: "pause.circle.fill", tint: .orange, action: nil)
        }
        if !store.bool("enabled") {
            return .init(kind: .paused, title: L10n.text("공유 창 바꾸기 꺼짐"),
                         detail: L10n.text("원격 연결 중에 원래 공유 창이 보입니다."),
                         symbol: "pause.circle.fill", tint: .secondary, action: .enableSettings)
        }
        // The mode's effect is explained next to the mode control; the status
        // says only whether the session window is found.
        let detail = found ? L10n.text("공유 창에 설정이 적용되었습니다.") : L10n.text("원격 연결이 시작되면 공유 창에 설정이 적용됩니다.")
        return found
            ? .init(kind: .working, title: L10n.text("작동 중"), detail: detail, symbol: "checkmark.circle.fill", tint: .green, action: nil)
            : .init(kind: .waiting, title: L10n.text("준비됨"), detail: detail, symbol: "checkmark.circle", tint: .green, action: nil)
    }

    /// The status when the original sharing window could not be confirmed visible again.
    static let restorationNeeded = StudioStatus(kind: .attention, title: L10n.text("원래 공유 창 복원 필요"),
        detail: SystemNames.pick(L10n.text("원래 공유 창이 다시 보이는지 확인하지 못했습니다. CRD Window Host의 손쉬운 사용 권한을 확인한 뒤 창 도우미 끄기를 다시 시도하세요. 복원이 확인될 때까지 창 도우미 파일은 유지됩니다."), L10n.text("원래 공유 창이 다시 보이는지 확인하지 못했습니다. CRD Window Host의 기기 제어 권한을 확인한 뒤 창 도우미 끄기를 다시 시도하세요. 복원이 확인될 때까지 창 도우미 파일은 유지됩니다.")),
        symbol: "exclamationmark.triangle.fill", tint: .orange, action: .retryTurnOff)

    /// Permission comes from the helper's own report while it runs. Otherwise
    /// an explicit permission check decides, and without one a coded
    /// accessibility_required failure of an inactive helper does.
    /// Readiness alone never says permission is missing.
    @MainActor static func permissionMissing(_ companion: CompanionService) -> Bool {
        guard let status = companion.status else { return false }
        let live = status.state == "active" && status.companionService.running
        // An unacknowledged refresh leaves only cached values; they are not a permission result.
        if live, status.runtime.refreshConfirmed != false, let reported = status.runtime.accessibility { return !reported }
        if let checked = companion.accessibilityAllowed { return !checked }
        guard !live, status.state != "active" else { return false }
        return companion.errorCode == "accessibility_required" || status.errorCode == "accessibility_required"
    }

    /// Runs a status action.
    @MainActor static func perform(_ action: Action, companion: CompanionService, store: SettingsStore) {
        switch action {
        case .turnOnHelper: companion.turnOn()
        case .restartHelper: companion.perform(.restart)
        case .openAccessibility: StudioLinks.requestAccessibility(companion)
        case .enableSettings: store.set("enabled", .bool(true))
        case .retryTurnOff: companion.perform(.restore)
        case .refreshStatus: companion.refresh(); store.refreshHost()
        }
    }
}

/// Opens the system settings the helper needs.
enum StudioLinks {
    /// First asks the helper to show the macOS request, so a first-time user finds
    /// CRD Window Host already listed, then opens Privacy & Security > Accessibility.
    @MainActor static func requestAccessibility(_ companion: CompanionService) {
        companion.perform(.requestPermission) { openAccessibilitySettings() }
    }
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}

/// Short facts for the helper page. Each fact appears once.
struct HelperFacts {
    let helper: String
    let permission: String
    let permissionMissing: Bool
    let window: String
    let crd: String
    let helperOn: Bool
    let windowFound: Bool
    /// The helper row blocks operation (needs a check, not ready, or did not stop cleanly).
    let helperNeedsAttention: Bool
    @MainActor init(companion: CompanionService, store: SettingsStore) {
        let status = companion.status
        let active = status?.state == "active"
        helperOn = active && companion.agentReady
        if !companion.canManage { helper = L10n.text("포함되지 않음") }
        else if let busy = companion.busyAction, !busy.isCheck {
            helper = busy == .restore ? L10n.text("끄는 중") : L10n.text("켜는 중")
        } else if status == nil { helper = L10n.text("확인 중") }
        else if companion.restorationBlocked { helper = L10n.text("확인 필요") }
        else if active && companion.agentReady { helper = L10n.text("켜짐") }
        // Switching is a short start; an active helper that never reports ready can stay that way.
        else if status?.state == "switching" { helper = L10n.text("시작 중") }
        else if active { helper = L10n.text("준비되지 않음") }
        else if ["rolled_back", "rollback_failed", "cleanup_failed"].contains(status?.state ?? "") { helper = L10n.text("확인 필요") }
        else { helper = L10n.text("꺼짐") }
        helperNeedsAttention = companion.canManage && [L10n.text("확인 필요"), L10n.text("준비되지 않음")].contains(helper)
        permissionMissing = StudioStatus.permissionMissing(companion)
        if permissionMissing { permission = L10n.text("허용 필요") }
        else if (status?.runtime.accessibility == true && !companion.refreshUnconfirmed) || companion.accessibilityAllowed == true { permission = L10n.text("허용됨") }
        else { permission = L10n.text("확인 전") }
        windowFound = helperOn && status?.runtime.originalWindowDetected == true
        if !helperOn { window = L10n.text("확인 전") }
        else { window = windowFound ? L10n.text("감지됨") : L10n.text("원격 연결 대기 중") }
        crd = !store.hostChecked ? L10n.text("확인 중") : store.host.version ?? L10n.text("설치되지 않음")
    }
}

/// User-facing text for the controller's error codes. Codes whose next
/// step is the same share one message; unknown codes use the general one.
enum HelperDiagnostic: Equatable {
    case permissionRequired, timedOut, busyElsewhere, unexpectedState, configMismatch
    case permissionCheckCleanup, permissionCheckFailed, restorationUnconfirmed, legacyRecord
    case helperUnverified, hostProblem, fileProblem, wrongUser, general

    init(code: String?) {
        switch code {
        case "accessibility_required": self = .permissionRequired
        case "command_timeout", "permission_probe_timeout": self = .timedOut
        case "operation_in_progress": self = .busyElsewhere
        case "helper_already_active", "helper_not_active", "helper_start_unconfirmed", "helper_stop_failed", "install_record_missing":
            self = .unexpectedState
        case "config_path_mismatch": self = .configMismatch
        case "permission_probe_cleanup_failed": self = .permissionCheckCleanup
        case "permission_probe_invalid", "helper_not_prepared": self = .permissionCheckFailed
        case "restoration_unconfirmed": self = .restorationUnconfirmed
        case "legacy_install_record": self = .legacyRecord
        case "helper_not_built", "helper_verification_failed", "signing_failed", "agent_identity_mismatch": self = .helperUnverified
        case "host_not_found", "host_verification_failed": self = .hostProblem
        case "file_access_denied", "file_io_failed", "file_not_found", "invalid_data": self = .fileProblem
        case "gui_user_required": self = .wrongUser
        default: self = .general // operation_failed, command_failed, invalid_arguments and unknown codes
        }
    }
    /// The localized message for the diagnostic, with the permission pane named for this macOS.
    var message: String {
        switch self {
        case .permissionRequired: return SystemNames.pick(L10n.text("창 도우미에 손쉬운 사용 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 CRD Window Host를 켜세요."), L10n.text("창 도우미에 기기 제어 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 기기 제어 및 데이터 접근에서 CRD Window Host를 켜세요."))
        case .timedOut: return L10n.text("창 도우미 작업이 제시간에 끝나지 않았습니다. 상태 새로고침을 누른 뒤 다시 시도하세요.")
        case .busyElsewhere: return L10n.text("다른 창 도우미 작업이 진행 중입니다. 끝난 뒤 다시 시도하세요.")
        case .unexpectedState: return L10n.text("창 도우미 상태가 예상과 다릅니다. 상태 새로고침을 누른 뒤 다시 시도하세요.")
        case .configMismatch: return L10n.text("설정 앱과 실행 중인 창 도우미가 서로 다른 설정 파일을 사용하고 있습니다. 같은 설정 파일을 사용하도록 맞춘 뒤 다시 시도하세요.")
        case .permissionCheckCleanup: return SystemNames.pick(L10n.text("손쉬운 사용 권한 확인을 마무리하지 못했습니다. 상태 새로고침을 누른 뒤 다시 시도하세요."), L10n.text("기기 제어 권한 확인을 마무리하지 못했습니다. 상태 새로고침을 누른 뒤 다시 시도하세요."))
        case .permissionCheckFailed: return SystemNames.pick(L10n.text("손쉬운 사용 권한을 확인하지 못했습니다. 상태 새로고침을 누른 뒤 다시 확인하세요."), L10n.text("기기 제어 권한을 확인하지 못했습니다. 상태 새로고침을 누른 뒤 다시 확인하세요."))
        case .restorationUnconfirmed: return StudioStatus.restorationNeeded.detail
        // An old install record does not allow the restoration-only retry; do not promise it.
        case .legacyRecord: return L10n.text("원래 공유 창이 다시 보이는지 확인하지 못해 창 도우미 파일을 유지했습니다. 상태 새로고침을 눌러 다시 확인하세요.")
        case .helperUnverified: return L10n.text("앱에 포함된 창 도우미를 확인하지 못했습니다. 앱을 다시 설치하세요.")
        case .hostProblem: return L10n.text("Chrome 원격 데스크톱을 확인하지 못했습니다. 올바르게 설치되어 있는지 확인하세요.")
        case .fileProblem: return L10n.text("필요한 파일을 읽거나 저장하지 못했습니다. 자세한 내용을 확인한 뒤 다시 시도하세요.")
        case .wrongUser: return L10n.text("이 Mac에 로그인한 사용자로 설정 앱을 실행하세요.")
        case .general: return L10n.text("창 도우미 작업을 완료하지 못했습니다. 잠시 후 다시 시도하세요.")
        }
    }
    /// The alert text: the action's problem, then incomplete cleanup as its own problem.
    @MainActor static func alertText(_ companion: CompanionService) -> String {
        let primary = companion.errorCode.map { HelperDiagnostic(code: $0).message } ?? HelperDiagnostic.general.message
        guard let cleanup = companion.status?.cleanupErrorCode, cleanup != companion.errorCode else { return primary }
        return primary + "\n\n" + L10n.format("창 도우미 마무리 작업도 끝내지 못했습니다. %@", HelperDiagnostic(code: cleanup).message)
    }
}
