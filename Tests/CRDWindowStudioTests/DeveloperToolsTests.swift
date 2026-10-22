import AppKit
import XCTest
import CRDSettingsCore
@testable import CRDWindowStudio

/// The command line developer tools check before every controller command: a fake `xcode-select`
/// and fake developer folders stand in for the real ones, the controller is a recording fake, and the
/// install request goes to a fake runner. No real `xcode-select`, Python or installer ever runs.
final class DeveloperToolsTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crd-developer-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// A fake `xcode-select` that prints `output` and exits with `status`, whatever it is asked.
    private func fakeSelect(printing output: String, status: Int32 = 0) throws -> URL {
        let url = directory.appendingPathComponent("xcode-select-\(UUID().uuidString)")
        try "#!/bin/sh\nprintf '%s\\n' '\(output)'\nexit \(status)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    /// A developer folder at `name` whose `usr/bin/python3` has `mode`, or no python3 when `mode` is nil.
    private func developerFolder(_ name: String, python mode: Int?) throws -> URL {
        let folder = directory.appendingPathComponent(name)
        let bin = folder.appendingPathComponent("usr/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if let mode {
            let python = bin.appendingPathComponent("python3")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: python.path)
        }
        return folder
    }

    /// The Command Line Tools layout and Xcode's both count when their python3 is executable.
    func testToolsCountInBothDeveloperFolderLayouts() throws {
        for name in ["Library/Developer/CommandLineTools", "Applications/Xcode.app/Contents/Developer"] {
            let folder = try developerFolder(name, python: 0o755)
            XCTAssertTrue(DeveloperTools.pythonInstalled(xcodeSelect: try fakeSelect(printing: folder.path)), name)
        }
    }

    /// No developer folder, a missing or non-executable python3, or an unreadable answer all mean missing.
    func testMissingToolsAreReportedWithoutStartingPython() throws {
        let unselected = try fakeSelect(printing: "xcode-select: error: unable to get active developer directory", status: 2)
        XCTAssertFalse(DeveloperTools.pythonInstalled(xcodeSelect: unselected))
        XCTAssertFalse(DeveloperTools.pythonInstalled(xcodeSelect: directory.appendingPathComponent("no-xcode-select")))
        let empty = try developerFolder("Library/Developer/CommandLineTools", python: nil)
        XCTAssertFalse(DeveloperTools.pythonInstalled(xcodeSelect: try fakeSelect(printing: empty.path)))
        let plain = try developerFolder("Plain/Developer", python: 0o644)
        XCTAssertFalse(DeveloperTools.pythonInstalled(xcodeSelect: try fakeSelect(printing: plain.path)))
        XCTAssertFalse(DeveloperTools.pythonInstalled(xcodeSelect: try fakeSelect(printing: "Library/Developer/CommandLineTools")))
        XCTAssertFalse(DeveloperTools.pythonInstalled(xcodeSelect: try fakeSelect(printing: "")))
    }

    /// The install button asks only `xcode-select --install`, which opens Apple's own installer.
    func testInstallRequestAsksXcodeSelectToInstall() {
        var requests: [[String]] = []
        DeveloperTools.requestInstall { executable, arguments in requests.append([executable.path] + arguments) }
        XCTAssertEqual(requests, [["/usr/bin/xcode-select", "--install"]])
    }

    // MARK: - The controller gate

    /// Whether the fake developer tools are installed; the test installs them midway.
    private final class FixtureTools: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var installed: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }
    /// Records every controller action the fake receives.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [CompanionService.Action] = []
        func add(_ action: CompanionService.Action) { lock.lock(); recorded.append(action); lock.unlock() }
        var actions: [CompanionService.Action] { lock.lock(); defer { lock.unlock() }; return recorded }
        var mutations: [CompanionService.Action] { actions.filter { $0 != .status } }
    }
    @MainActor private func settle(_ service: CompanionService) async throws {
        while service.busy { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Without the tools no controller command starts, the launch status check included. The status
    /// says so and offers Turn On; Turn On alerts with the install; after the install, Turn On runs the
    /// usual first turn-on (the permission request, then install).
    @MainActor func testMissingToolsStartNoCommandAndTurnOnOffersTheInstall() async throws {
        let tools = FixtureTools(), recorder = Recorder()
        let status = Data(#"{"state":"not_installed","companionPath":"/fixture","companionService":{"loaded":false,"running":false},"originalService":{"loaded":false,"running":false},"runtime":{"confirmed":false},"originalBundleModifiedByCompanion":false}"#.utf8)
        let granted = Data(#"{"accessibility":true}"#.utf8)
        let service = CompanionService(script: URL(fileURLWithPath: "/fixture/companionctl.py"), includesRuntime: true, execute: { _, action in
            recorder.add(action)
            return action == .permissions || action == .requestPermission ? granted : status
        }, developerTools: { tools.installed })
        let repository = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: try .load())
        let store = SettingsStore(repository: repository, inspectHost: {
            HostInspection(version: "155.0.8059", patchInstalled: true, running: false, windowObserved: false, detail: "fixture")
        })
        store.refreshHost()
        while !store.hostChecked { try await Task.sleep(for: .milliseconds(10)) }

        // The status check at launch starts nothing and alerts nothing; the status explains.
        service.refresh(); try await settle(service)
        XCTAssertEqual(recorder.actions, [])
        XCTAssertTrue(service.developerToolsMissing)
        XCTAssertNil(service.status)
        XCTAssertNil(service.alertKey, "A status refresh does not alert")
        let needed = StudioStatus.make(companion: service, store: store)
        XCTAssertEqual(needed.kind, .developerToolsNeeded)
        XCTAssertEqual(needed.title, L10n.text("명령어 라인 개발자 도구 필요"))
        XCTAssertEqual(needed.action, .turnOnHelper)
        XCTAssertTrue(needed.needsAttention)
        XCTAssertNotNil(NSImage(systemSymbolName: needed.symbol, accessibilityDescription: nil), needed.symbol)
        XCTAssertTrue(service.canEnable, "Turn On checks again")
        XCTAssertEqual(HelperFacts(companion: service, store: store).helper, L10n.text("확인 필요"))

        // Turn On while still missing: nothing starts, and the alert names the tools and the next step.
        StudioStatus.perform(.turnOnHelper, companion: service, store: store); try await settle(service)
        XCTAssertEqual(recorder.actions, [])
        XCTAssertEqual(service.errorCode, DeveloperTools.missingCode)
        XCTAssertTrue(CompanionService.shouldAlert(service.alertKey, dismissed: nil))
        XCTAssertEqual(HelperDiagnostic(code: service.errorCode), .developerToolsMissing)
        XCTAssertEqual(HelperDiagnostic.alertText(service),
                       L10n.text("창 도우미를 켜려면 명령어 라인 개발자 도구가 필요합니다. 설치를 마친 뒤 창 도우미 켜기를 다시 누르세요."))
        // Every other controller action is held back the same way.
        for action in [CompanionService.Action.permissions, .requestPermission, .prepare, .install, .restart, .restore] {
            service.perform(action); try await settle(service)
            XCTAssertEqual(service.errorCode, DeveloperTools.missingCode, action.rawValue)
        }
        XCTAssertEqual(recorder.actions, [])

        // After the install, Turn On checks again and goes on as a first turn-on.
        tools.installed = true
        service.turnOn(); try await settle(service)
        XCTAssertFalse(service.developerToolsMissing)
        XCTAssertEqual(recorder.mutations, [.requestPermission, .install], "The macOS request comes first; install follows a granted check")
        XCTAssertEqual(recorder.actions.first, .status)
        XCTAssertNil(service.errorCode)
    }

    /// Every app string of this check has an English translation and uses Apple's own term.
    func testDeveloperToolsTextUsesAppleTermsInBothLanguages() {
        for key in ["명령어 라인 개발자 도구 필요", "명령어 라인 개발자 도구 설치",
                    "창 도우미를 켜려면 명령어 라인 개발자 도구가 필요합니다. 창 도우미 켜기를 눌러 설치하세요.",
                    "창 도우미를 켜려면 명령어 라인 개발자 도구가 필요합니다. 설치를 마친 뒤 창 도우미 켜기를 다시 누르세요."] {
            XCTAssertTrue(L10n.text(key, language: "ko").contains("명령어 라인 개발자 도구"), key)
            XCTAssertTrue(L10n.text(key, language: "en").localizedCaseInsensitiveContains("command line developer tools"), key)
        }
        XCTAssertTrue(L10n.text("창 도우미를 켜려면 명령어 라인 개발자 도구가 필요합니다. 설치를 마친 뒤 창 도우미 켜기를 다시 누르세요.", language: "en")
            .contains(L10n.text("창 도우미 켜기", language: "en")), "The alert names the Turn On Window Helper button")
    }
}
