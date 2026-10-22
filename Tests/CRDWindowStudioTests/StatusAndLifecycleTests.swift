import ServiceManagement
import XCTest
import CRDSettingsCore
@testable import CRDWindowStudio

/// Status, permission, restoration, error alerts, quitting with unsaved edits, preview geometry and
/// the login item, driven through the controller and host-inspection seams.
final class StatusAndLifecycleTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// A store over a temporary configuration in original mode, with fixed host facts.
    @MainActor private func makeStore(host: HostInspection) throws -> SettingsStore {
        let repository = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: try .load())
        try repository.save(["mode": .string("original")])
        return SettingsStore(repository: repository, inspectHost: { host })
    }
    /// The controller's status JSON for `state`, with an optional runtime and extra top-level fields.
    private static func status(_ state: String, running: Bool, runtime: String = #"{"confirmed":false}"#, extra: String = "") -> Data {
        Data(#"{"state":"\#(state)","companionPath":"/fixture","companionService":{"loaded":\#(running),"running":\#(running)},"originalService":{"loaded":false,"running":false},"runtime":\#(runtime),"originalBundleModifiedByCompanion":false\#(extra)}"#.utf8)
    }
    /// A service whose fake controller answers `status`, answers permission checks with `permissions`,
    /// and fails `failing` with the error code `code`.
    @MainActor private func companion(_ status: Data, permissions: Data? = nil, failing: CompanionService.Action? = nil,
                                      code: String = "accessibility_required") -> CompanionService {
        CompanionService(script: URL(fileURLWithPath: "/fixture/companionctl.py"), includesRuntime: true) { _, action in
            if action == failing {
                throw NSError(domain: "CRDCompanionService", code: 1, userInfo: [BoundedProcess.errorCodeKey: code, NSLocalizedDescriptionKey: "fixture failure"])
            }
            if action == .permissions || action == .requestPermission, let permissions { return permissions }
            return status
        }
    }
    /// Waits until the service finishes its action.
    @MainActor private func settle(_ service: CompanionService) async throws {
        while service.busy { try await Task.sleep(for: .milliseconds(10)) }
    }
    private static let installed = HostInspection(version: "155.0.8059", patchInstalled: true, running: false, windowObserved: false, detail: "fixture")
    private static let absent = HostInspection(version: nil, patchInstalled: false, running: false, windowObserved: false, detail: "fixture")

    // An unchecked host is not a missing host.
    @MainActor func testUncheckedHostShowsCheckingUntilInspectionFinishes() async throws {
        let store = try makeStore(host: Self.installed)
        let service = companion(Self.status("restored", running: false))
        service.refresh(); try await settle(service)
        XCTAssertFalse(store.hostChecked)
        XCTAssertEqual(StudioStatus.make(companion: service, store: store).kind, .checking)
        XCTAssertEqual(HelperFacts(companion: service, store: store).crd, L10n.text("확인 중"))
        store.refreshHost()
        while !store.hostChecked { try await Task.sleep(for: .milliseconds(10)) }
        let ready = StudioStatus.make(companion: service, store: store)
        XCTAssertEqual(ready.kind, .helperOff); XCTAssertEqual(ready.action, .turnOnHelper)

        let missingStore = try makeStore(host: Self.absent)
        missingStore.refreshHost()
        while !missingStore.hostChecked { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(StudioStatus.make(companion: service, store: missingStore).kind, .crdMissing)
    }

    // An explicit denial or a coded permission failure of an inactive helper leads to the permission action.
    @MainActor func testPermissionDenialWhileOffOffersThePermissionAction() async throws {
        let store = try makeStore(host: Self.installed)
        store.refreshHost(); while !store.hostChecked { try await Task.sleep(for: .milliseconds(10)) }

        let off = companion(Self.status("restored", running: false), permissions: Data(#"{"accessibility":false}"#.utf8))
        off.refresh(); try await settle(off)
        XCTAssertEqual(StudioStatus.make(companion: off, store: store).action, .turnOnHelper) // nothing known yet
        off.perform(.permissions); try await settle(off)
        let denied = StudioStatus.make(companion: off, store: store)
        XCTAssertEqual(denied.kind, .permissionNeeded); XCTAssertEqual(denied.action, .openAccessibility)
        XCTAssertEqual(HelperFacts(companion: off, store: store).permission, L10n.text("허용 필요"))

        let rolledBack = companion(Self.status("rolled_back", running: false, extra: #","errorCode":"accessibility_required""#))
        rolledBack.refresh(); try await settle(rolledBack)
        XCTAssertEqual(StudioStatus.make(companion: rolledBack, store: store).action, .openAccessibility)

        let failedInstall = companion(Self.status("prepared", running: false), failing: .install)
        failedInstall.perform(.install); try await settle(failedInstall)
        XCTAssertEqual(failedInstall.errorCode, "accessibility_required")
        XCTAssertEqual(StudioStatus.make(companion: failedInstall, store: store).action, .openAccessibility)

        // cleanup_failed keeps its own recovery, even with a denial on record.
        let cleanup = companion(Self.status("cleanup_failed", running: false), permissions: Data(#"{"accessibility":false}"#.utf8))
        cleanup.perform(.permissions); try await settle(cleanup)
        let stuck = StudioStatus.make(companion: cleanup, store: store)
        XCTAssertEqual(stuck, StudioStatus.restorationNeeded); XCTAssertEqual(stuck.action, .retryTurnOff)

        // A fresh live runtime report outranks an older probe result.
        let live = companion(Self.status("active", running: true, runtime: #"{"confirmed":true,"agentReady":true,"observerReady":true,"backendKind":"accessibility-overlay","accessibility":true}"#),
                             permissions: Data(#"{"accessibility":false}"#.utf8))
        live.perform(.permissions); try await settle(live)
        XCTAssertEqual(live.accessibilityAllowed, false)
        XCTAssertFalse(StudioStatus.permissionMissing(live))
    }

    // Restoration and refresh states from newer helpers; older helpers still decode.
    @MainActor func testRestorationBlockedAndUnconfirmedRefresh() async throws {
        let store = try makeStore(host: Self.installed)
        store.refreshHost(); while !store.hostChecked { try await Task.sleep(for: .milliseconds(10)) }
        let ready = #""confirmed":true,"agentReady":true,"observerReady":true,"backendKind":"accessibility-overlay""#

        let old = companion(Self.status("active", running: true, runtime: "{\(ready),\"accessibility\":true}"))
        old.refresh(); try await settle(old)
        XCTAssertNil(old.status?.runtime.restorationBlocked); XCTAssertNil(old.status?.runtime.refreshConfirmed)
        XCTAssertEqual(StudioStatus.make(companion: old, store: store).kind, .waiting)

        let pending = companion(Self.status("active", running: true, runtime: "{\(ready),\"accessibility\":true,\"restorationPending\":true,\"restorationBlocked\":false,\"refreshConfirmed\":true,\"originalWindowDetected\":true}"))
        pending.refresh(); try await settle(pending)
        XCTAssertEqual(StudioStatus.make(companion: pending, store: store).kind, .working) // pending alone is normal

        let blocked = companion(Self.status("active", running: true, runtime: #"{"confirmed":true,"agentReady":false,"observerReady":true,"backendKind":"accessibility-overlay","accessibility":false,"restorationPending":true,"restorationBlocked":true,"refreshConfirmed":false}"#))
        blocked.refresh(); try await settle(blocked)
        XCTAssertEqual(StudioStatus.make(companion: blocked, store: store), StudioStatus.restorationNeeded) // before permission, refresh and restart
        XCTAssertFalse(blocked.canEnable); XCTAssertTrue(blocked.canDisable)
        XCTAssertEqual(HelperFacts(companion: blocked, store: store).helper, L10n.text("확인 필요"))

        let stale = companion(Self.status("active", running: true, runtime: "{\(ready),\"accessibility\":false,\"refreshConfirmed\":false}"),
                              permissions: Data(#"{"accessibility":true}"#.utf8))
        stale.refresh(); try await settle(stale)
        XCTAssertFalse(StudioStatus.permissionMissing(stale)) // cached false is not a result
        let check = StudioStatus.make(companion: stale, store: store)
        XCTAssertEqual(check.action, .refreshStatus); XCTAssertEqual(check.title, L10n.text("창 도우미 상태 확인 필요"))
        XCTAssertEqual(HelperFacts(companion: stale, store: store).permission, L10n.text("확인 전"))
        stale.perform(.permissions); try await settle(stale)
        XCTAssertEqual(HelperFacts(companion: stale, store: store).permission, L10n.text("허용됨")) // an explicit check still counts

        XCTAssertEqual(HelperDiagnostic(code: "restoration_unconfirmed").message, StudioStatus.restorationNeeded.detail)
        XCTAssertEqual(HelperDiagnostic(code: "legacy_install_record"), .legacyRecord)
        XCTAssertNotEqual(HelperDiagnostic(code: "legacy_install_record").message, StudioStatus.restorationNeeded.detail)
    }

    // The permission pane name follows the running macOS.
    @MainActor func testPermissionPaneNameFollowsSystemVersion() async throws {
        XCTAssertEqual(SystemNames.pick("old", "new", deviceControl: false), "old")
        XCTAssertEqual(SystemNames.pick("old", "new", deviceControl: true), "new")
        XCTAssertEqual(SystemNames.usesDeviceControlName, ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
        // Every macOS 27 pair exists in both catalogs and does not say Accessibility.
        for modern in ["기기 제어 권한", "기기 제어 권한 필요", "기기 제어 설정 열기", "기기 제어 권한 확인 중", "기기 제어 권한: %@",
                       "시스템 설정 > 개인정보 보호 및 보안 > 기기 제어 및 데이터 접근에서 CRD Window Host를 켜세요.",
                       "창 도우미에 기기 제어 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 기기 제어 및 데이터 접근에서 CRD Window Host를 켜세요."] {
            let english = L10n.text(modern, language: "en")
            XCTAssertNotEqual(english, modern); XCTAssertFalse(english.contains("Accessibility"), english)
            XCTAssertEqual(L10n.text(modern, language: "ko"), modern)
        }
        let store = try makeStore(host: Self.installed)
        store.refreshHost(); while !store.hostChecked { try await Task.sleep(for: .milliseconds(10)) }
        let off = companion(Self.status("restored", running: false), permissions: Data(#"{"accessibility":false}"#.utf8))
        off.perform(.permissions); try await settle(off)
        let status = StudioStatus.make(companion: off, store: store)
        let deviceControl = SystemNames.usesDeviceControlName
        XCTAssertEqual(status.title, deviceControl ? L10n.text("기기 제어 권한 필요") : L10n.text("손쉬운 사용 권한 필요"))
        XCTAssertEqual(status.actionTitle, deviceControl ? L10n.text("기기 제어 설정 열기") : L10n.text("손쉬운 사용 설정 열기"))
        XCTAssertEqual(off.permissionDescription, deviceControl ? L10n.format("기기 제어 권한: %@", L10n.text("허용 필요")) : L10n.format("손쉬운 사용 권한: %@", L10n.text("허용 필요")))
    }

    // A new explicit attempt alerts again; passive refreshes do not repeat a dismissed error.
    @MainActor func testIdenticalRetryErrorAlertsAgainButRefreshDoesNot() async throws {
        let service = companion(Self.status("prepared", running: false, extra: #","errorCode":"helper_not_active","error":"receipt detail""#),
                                failing: .install, code: "helper_not_active")
        service.perform(.install); try await settle(service)
        let first = service.alertKey
        XCTAssertTrue(CompanionService.shouldAlert(first, dismissed: nil))
        let dismissed = first?.merged(with: nil)
        service.refresh(); try await settle(service)
        XCTAssertNotNil(service.alertKey)
        XCTAssertFalse(CompanionService.shouldAlert(service.alertKey, dismissed: dismissed))
        service.refresh(); try await settle(service)
        XCTAssertFalse(CompanionService.shouldAlert(service.alertKey, dismissed: dismissed))
        service.perform(.install); try await settle(service)
        XCTAssertEqual(service.alertKey?.codes, first?.codes)
        XCTAssertTrue(CompanionService.shouldAlert(service.alertKey, dismissed: dismissed))
    }

    // Valid drafts are committed before the final flush; invalid ones are not.
    @MainActor func testTerminationCommitsValidDraftsThenFlushes() throws {
        let store = try makeStore(host: Self.installed)
        store.stageDraft("text-text") { store.set("text", .string("draft caption")) }
        store.stageDraft("number-width") {
            guard let number = StudioNumber.parse("abc"), let changes = NumericEdit.changes(key: "width", number: number, current: store.values) else { return }
            store.update(changes)
        }
        store.stageDraft("cleared") { store.set("height", .number(99)) }
        store.clearDraft("cleared")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        let saved = try store.repository.load()
        XCTAssertEqual(saved["text"], .string("draft caption"))
        XCTAssertEqual(saved["width"], store.schema.defaults["width"])
        XCTAssertEqual(saved["height"], store.schema.defaults["height"])
        XCTAssertEqual(StudioNumber.parse(" 12,5 "), 12.5)
        XCTAssertNil(StudioNumber.parse("inf"))
    }

    // The preview's own report waits for the gesture to end; external edits apply at once.
    func testPreviewDefersOwnGeometryDuringGesture() {
        XCTAssertFalse(PreviewWindowController.appliesFrame(reportedByWindow: true, gestureActive: true))
        XCTAssertTrue(PreviewWindowController.appliesFrame(reportedByWindow: true, gestureActive: false))
        XCTAssertTrue(PreviewWindowController.appliesFrame(reportedByWindow: false, gestureActive: true))
    }

    // Login item errors and approval reach StartupRows and clear when resolved.
    @MainActor func testLoginItemProblemsAreShownAndCleared() throws {
        final class FakeLogin { var status: SMAppService.Status = .notRegistered; var fail = false }
        let fake = FakeLogin()
        let control = LoginItemControl(status: { fake.status },
                                       register: { if fake.fail { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "denied"]) }; fake.status = .requiresApproval },
                                       unregister: { fake.status = .notRegistered })
        let defaults = UserDefaults(suiteName: "crd.tests.\(UUID().uuidString)")!
        let preferences = AppPreferences(defaults: defaults, loginItem: control)
        XCTAssertNil(preferences.loginProblem)
        preferences.setLoginEnabled(true)
        XCTAssertFalse(preferences.loginEnabled); XCTAssertTrue(preferences.loginNeedsApproval)
        XCTAssertEqual(preferences.loginProblem, L10n.text("시스템 설정 > 일반 > 로그인 항목 및 확장 프로그램에서 설정 앱을 허용하세요."))
        fake.status = .enabled; preferences.refreshLoginStatus()
        XCTAssertTrue(preferences.loginEnabled); XCTAssertNil(preferences.loginProblem)
        fake.status = .notRegistered; fake.fail = true; preferences.refreshLoginStatus()
        preferences.setLoginEnabled(true)
        XCTAssertEqual(preferences.loginError, L10n.format("로그인 항목을 바꾸지 못했습니다. %@", "denied"))
        fake.fail = false; preferences.setLoginEnabled(true)
        XCTAssertNil(preferences.loginError) // a new attempt clears the old error
        XCTAssertTrue(preferences.loginNeedsApproval)
    }
}
