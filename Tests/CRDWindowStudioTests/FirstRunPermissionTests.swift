import XCTest
import CRDSettingsCore
@testable import CRDWindowStudio

/// With the permission unknown and no helper installed, Turn On asks macOS first and
/// installs only after a granted check. Every command goes to a recording fake; no process runs.
final class FirstRunPermissionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crd-first-run-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// Records every controller action the fake receives.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [CompanionService.Action] = []
        func add(_ action: CompanionService.Action) { lock.lock(); recorded.append(action); lock.unlock() }
        var actions: [CompanionService.Action] { lock.lock(); defer { lock.unlock() }; return recorded }
        var mutations: [CompanionService.Action] { actions.filter { $0 != .status } }
    }
    private static func status(_ state: String) -> Data {
        Data(#"{"state":"\#(state)","companionPath":"/fixture","companionService":{"loaded":false,"running":false},"originalService":{"loaded":false,"running":false},"runtime":{"confirmed":false},"originalBundleModifiedByCompanion":false}"#.utf8)
    }
    /// A service whose fake controller reports `state` and answers permission checks with `allowed`.
    @MainActor private func service(state: String, allowed: Bool, recorder: Recorder) -> CompanionService {
        let status = Self.status(state), permission = Data(#"{"accessibility":\#(allowed)}"#.utf8)
        return CompanionService(script: URL(fileURLWithPath: "/fixture/companionctl.py"), includesRuntime: true) { _, action in
            recorder.add(action)
            return action == .permissions || action == .requestPermission ? permission : status
        }
    }
    /// A store over a temporary configuration, with the host already inspected.
    @MainActor private func store() async throws -> SettingsStore {
        let repository = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: try .load())
        let store = SettingsStore(repository: repository, inspectHost: {
            HostInspection(version: "155.0.8059", patchInstalled: true, running: false, windowObserved: false, detail: "fixture")
        })
        store.refreshHost()
        while !store.hostChecked { try await Task.sleep(for: .milliseconds(10)) }
        return store
    }
    @MainActor private func settle(_ service: CompanionService) async throws {
        while service.busy { try await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor func testFirstTurnOnRequestsThePermissionBeforeInstalling() async throws {
        let store = try await store(), recorder = Recorder()
        let companion = service(state: "not_installed", allowed: true, recorder: recorder)
        companion.refresh(); try await settle(companion)
        let off = StudioStatus.make(companion: companion, store: store)
        XCTAssertEqual(off.kind, .helperOff); XCTAssertEqual(off.action, .turnOnHelper)
        XCTAssertTrue(companion.permissionUnknownBeforeInstall)
        StudioStatus.perform(.turnOnHelper, companion: companion, store: store)
        try await settle(companion)
        XCTAssertEqual(recorder.mutations, [.requestPermission, .install], "The macOS request comes first; install follows a granted check")
        XCTAssertEqual(companion.accessibilityAllowed, true)
    }

    @MainActor func testDeniedFirstRequestInstallsNothingAndOffersThePermissionAction() async throws {
        let store = try await store(), recorder = Recorder()
        let companion = service(state: "prepared", allowed: false, recorder: recorder)
        companion.refresh(); try await settle(companion)
        companion.turnOn(); try await settle(companion)
        XCTAssertEqual(recorder.mutations, [.requestPermission], "A denial never runs install")
        XCTAssertFalse(recorder.actions.contains(.install))
        let denied = StudioStatus.make(companion: companion, store: store)
        XCTAssertEqual(denied.kind, .permissionNeeded); XCTAssertEqual(denied.action, .openAccessibility)
        XCTAssertEqual(HelperFacts(companion: companion, store: store).permission, L10n.text("허용 필요"))
        XCTAssertNil(companion.errorCode, "Nothing failed: no bundle was archived and no error alert is due")
        XCTAssertFalse(companion.permissionUnknownBeforeInstall, "Once checked, the existing recovery path applies")
    }

    @MainActor func testKnownPermissionAndOtherStatesInstallDirectly() async throws {
        let recorder = Recorder()
        let checked = service(state: "restored", allowed: true, recorder: recorder)
        checked.perform(.permissions); try await settle(checked)
        checked.turnOn(); try await settle(checked)
        XCTAssertEqual(recorder.mutations, [.permissions, .install], "A granted check already made goes straight to install")

        let rolledBackRecorder = Recorder()
        let rolledBack = service(state: "rolled_back", allowed: true, recorder: rolledBackRecorder)
        rolledBack.refresh(); try await settle(rolledBack)
        XCTAssertFalse(rolledBack.permissionUnknownBeforeInstall)
        rolledBack.turnOn(); try await settle(rolledBack)
        XCTAssertEqual(rolledBackRecorder.mutations, [.install])
    }
}
