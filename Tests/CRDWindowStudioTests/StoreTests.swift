import XCTest
import CRDSettingsCore
@testable import CRDWindowStudio

/// In-memory launch preferences.
private final class FixturePreferences: UserDefaults {
    var values: [String: Bool] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] ?? false }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
}
/// Reports whether a fake command runs for the first time.
private final class FixtureCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func first() -> Bool { lock.withLock { calls += 1; return calls == 1 } }
}
/// Records the arguments of every fake command.
private final class FixtureCommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String]] = []
    func record(_ arguments: [String]) { lock.withLock { entries.append(arguments) } }
    var all: [[String]] { lock.withLock { entries } }
}

/// The settings store and the helper service: permission requests, decoding, merged saves,
/// missing and invalid files, the file watcher, launch policy and failed actions.
final class StoreTests: XCTestCase {
    @MainActor func testPermissionRequestPromptsOnlyFromTheMainAction() async throws {
        let log = FixtureCommandLog()
        let status = Data(#"{"state":"active","companionPath":"/fixture","companionService":{"loaded":true,"running":true,"pid":123},"originalService":{"loaded":false,"running":false},"runtime":{"confirmed":true,"agentReady":true,"observerReady":true,"backendKind":"accessibility-overlay","accessibility":false},"originalBundleModifiedByCompanion":false}"#.utf8)
        let service = CompanionService(script: URL(fileURLWithPath: "/fixture/companionctl.py"), includesRuntime: true) { script, action in
            log.record(CompanionService.commandArguments(script: script, action: action))
            return action.arguments.first == "permissions" ? Data(#"{"accessibility":false}"#.utf8) : status
        }
        var completed = false
        service.perform(.requestPermission) { completed = true }
        while service.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(completed)
        service.perform(.permissions)
        while service.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.all, [["/fixture/companionctl.py", "permissions", "--prompt"], ["/fixture/companionctl.py", "status"],
                                 ["/fixture/companionctl.py", "permissions"], ["/fixture/companionctl.py", "status"]])
        XCTAssertEqual(service.accessibilityAllowed, false)
        XCTAssertTrue(CompanionService.Action.requestPermission.isCheck)
        // A busy service still runs the follow-up (opening System Settings) at once.
        let blocked = CompanionService(script: nil, includesRuntime: true) { _, _ in Data() }
        var ranAnyway = false
        blocked.perform(.requestPermission) { ranAnyway = true }
        XCTAssertTrue(ranAnyway)
    }
    func testRuntimeDecodesOptionalPermissionAndDetectionFields() throws {
        let reported = Data(#"{"confirmed":false,"agentReady":false,"accessibility":false,"stopActionAvailable":false,"enabled":true,"effectiveMode":"original","detectionReason":"accessibility-required"}"#.utf8)
        let runtime = try JSONDecoder().decode(CompanionStatus.RuntimeState.self, from: reported)
        XCTAssertEqual(runtime.accessibility, false)
        XCTAssertEqual(runtime.stopActionAvailable, false)
        XCTAssertEqual(runtime.enabled, true)
        XCTAssertEqual(runtime.effectiveMode, "original")
        XCTAssertEqual(runtime.detectionReason, "accessibility-required")
        let older = try JSONDecoder().decode(CompanionStatus.RuntimeState.self, from: Data(#"{"confirmed":false,"agentReady":false}"#.utf8))
        XCTAssertNil(older.accessibility) // Lack of readiness is not a permission denial.
        XCTAssertNil(older.stopActionAvailable)
        XCTAssertNil(older.enabled)
        XCTAssertNil(older.effectiveMode)
        XCTAssertNil(older.detectionReason)
    }
    @MainActor func testPendingEditMergesExternalGeometryAndCoalesces() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: try .load())
        try repository.save(["mode": .string("original")])
        let store = SettingsStore(repository: repository)
        store.set("width", .number(-100))
        XCTAssertEqual(store.values["width"], repository.schema.defaults["width"])
        XCTAssertNotNil(store.errorMessage)
        for width in 500...600 { store.set("width", .number(Double(width))) }
        XCTAssertEqual(try repository.load()["width"], repository.schema.defaults["width"])
        try repository.update(["x": .number(31), "y": .number(42)])
        store.flush()
        let saved = try repository.load()
        XCTAssertEqual(saved["width"], .number(600))
        XCTAssertEqual(saved["x"], .number(31))
        XCTAssertEqual(store.values, saved)
    }
    @MainActor func testMissingPreviouslyReadFileKeepsValuesAndBlocksSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: try .load())
        try repository.save(["mode": .string("original"), "width": .number(777)])
        let store = SettingsStore(repository: repository)
        try FileManager.default.removeItem(at: repository.url)
        store.reload()
        XCTAssertEqual(store.loadError, .missing)
        XCTAssertFalse(store.canSave)
        XCTAssertFalse(store.requiresRecreation)
        XCTAssertEqual(store.string("mode"), "original")
        XCTAssertEqual(store.number("width"), 777)
        store.set("height", .number(60)); store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url.path))
        XCTAssertNotNil(store.errorMessage)
        try repository.save(["mode": .string("custom"), "width": .number(888)])
        store.reload(); store.flush()
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try repository.load()["width"], .number(888))
        XCTAssertEqual(try repository.load()["height"], .number(60))
    }
    @MainActor func testInvalidFileAtLaunchBlocksEditsAndResetUntilExplicitBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: try .load())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = Data(#"{"width":-1,"mode":"original"}"#.utf8)
        try invalid.write(to: repository.url)
        let store = SettingsStore(repository: repository)
        XCTAssertTrue(store.requiresRecreation); XCTAssertFalse(store.canSave)
        store.set("width", .number(400)); store.flush(); store.restoreDefaults(); store.reload()
        XCTAssertEqual(store.values, repository.schema.defaults)
        XCTAssertEqual(try Data(contentsOf: repository.url), invalid)
        XCTAssertNil(store.lastBackupURL)
        store.recreateWithBackup()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.lastBackupURL)), invalid)
        XCTAssertNil(store.loadError); XCTAssertTrue(store.canSave)
        store.set("width", .number(700)); store.flush()
        XCTAssertEqual(try repository.load()["width"], .number(700))
    }
    @MainActor func testCorruptionDuringPendingSaveKeepsBytesAndLocksFurtherEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: try .load())
        try repository.save(["mode": .string("original")])
        let store = SettingsStore(repository: repository)
        store.set("width", .number(600))
        let invalid = Data("{unfinished external edit".utf8)
        try invalid.write(to: repository.url, options: .atomic)
        store.flush()
        XCTAssertTrue(store.requiresRecreation)
        store.set("height", .number(70)); store.restoreDefaults()
        XCTAssertEqual(try Data(contentsOf: repository.url), invalid)
        // Removal after corruption must not turn it into a fresh first run.
        try FileManager.default.removeItem(at: repository.url)
        store.reload(); store.flush(); store.recreateWithBackup()
        XCTAssertTrue(store.requiresRecreation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url.path))
        try invalid.write(to: repository.url)
        store.recreateWithBackup()
        XCTAssertEqual(store.values, repository.schema.defaults) // Old pending edits were discarded.
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.lastBackupURL)), invalid)
    }
    @MainActor func testFirstRunMissingFileRemainsEditableAndOrdinaryResetBacksUp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: try .load())
        let store = SettingsStore(repository: repository)
        XCTAssertNil(store.loadError); XCTAssertTrue(store.canSave)
        XCTAssertEqual(store.string("mode"), "custom")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url.path))
        store.set("mode", .string("original")); store.flush()
        let original = try Data(contentsOf: repository.url)
        store.restoreDefaults()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.lastBackupURL)), original)
        XCTAssertEqual(try repository.load(), repository.schema.defaults)
        XCTAssertEqual(store.string("mode"), "custom")
    }
    @MainActor func testWatcherInPlaceAtomicReplacementAndDirectoryRecreation() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        try Data("one".utf8).write(to: file)
        var changes = 0
        let watcher = ConfigurationWatcher(file: file) { changes += 1 }
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("two".utf8)); try handle.close()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(changes, 1)
        try Data("three".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(changes, 2)
        try FileManager.default.removeItem(at: directory)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(changes, 3)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("four".utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(changes, 4)
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("runtime-status.json"))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(changes, 4)
        withExtendedLifetime(watcher) {}
    }
    @MainActor func testDisplayFallbackAndBackgroundLaunchPolicy() {
        XCTAssertEqual(PreviewWindowController.screenIndex(2, count: 2), 0)
        XCTAssertEqual(PreviewWindowController.screenIndex(1, count: 2), 1)
        XCTAssertEqual(PreviewWindowController.screenIndex(-1, count: 2), 0)
        let defaults = FixturePreferences()
        defaults.set(false, forKey: "openSettingsAtLaunch")
        defaults.set(false, forKey: "showPreviewAtLaunch")
        XCTAssertFalse(StudioAppDelegate.shouldActivateAtLaunch(defaults: defaults, arguments: []))
        XCTAssertTrue(StudioAppDelegate.shouldActivateAtLaunch(defaults: defaults, arguments: ["--show-settings"]))
        defaults.set(true, forKey: "showPreviewAtLaunch")
        XCTAssertTrue(StudioAppDelegate.shouldActivateAtLaunch(defaults: defaults, arguments: []))
    }
    @MainActor func testFailedActionRefreshesCleanupStateAndAllowsDisable() async throws {
        let data = Data(#"{"state":"cleanup_failed","companionPath":"/fixture","companionService":{"loaded":true,"running":false},"originalService":{"loaded":false,"running":false},"runtime":{"confirmed":false},"originalBundleModifiedByCompanion":false,"cleanupError":"fixture cleanup error"}"#.utf8)
        let service = CompanionService(script: URL(fileURLWithPath: "/fixture"), includesRuntime: true) { _, action in
            if action == .restart { throw NSError(domain: "fixture action", code: 1) }
            return data
        }
        service.perform(.restart)
        while service.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(service.status?.state, "cleanup_failed")
        XCTAssertEqual(service.summaryKey, "완전히 꺼지지 않음")
        XCTAssertTrue(service.canDisable); XCTAssertFalse(service.canEnable)
        XCTAssertFalse(service.agentReady)
        XCTAssertTrue(service.errorMessage?.contains("fixture action") == true)
        XCTAssertTrue(service.errorMessage?.contains("fixture cleanup error") == true)
    }
    @MainActor func testPermissionFailureCodeSurvivesStatusRefreshAndRetainsCleanupCode() async throws {
        let data = Data(#"{"state":"cleanup_failed","companionPath":"/fixture","companionService":{"loaded":false,"running":false},"originalService":{"loaded":false,"running":false},"runtime":{"confirmed":false},"originalBundleModifiedByCompanion":false,"errorCode":"accessibility_required","error":"fixture permission detail","cleanupErrorCode":"restoration_unconfirmed","cleanupError":"fixture cleanup detail"}"#.utf8)
        let service = CompanionService(script: URL(fileURLWithPath: "/fixture"), includesRuntime: true) { _, action in
            if action == .install {
                throw NSError(domain: "CRDCompanionService", code: 1, userInfo: [
                    BoundedProcess.errorCodeKey: "accessibility_required", NSLocalizedDescriptionKey: "fixture permission detail"])
            }
            return data
        }
        service.perform(.install)
        while service.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(service.errorCode, "accessibility_required")
        XCTAssertEqual(service.status?.cleanupErrorCode, "restoration_unconfirmed")
        XCTAssertEqual(service.errorMessage, "fixture permission detail\nfixture cleanup detail")
        service.refresh()
        while service.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(service.errorCode, "accessibility_required")
        XCTAssertTrue(service.canDisable); XCTAssertFalse(service.canEnable)
    }
    @MainActor func testFailedStatusClearsOldReadiness() async throws {
        let state = FixtureCommandState()
        let active = Data(#"{"state":"active","companionPath":"/fixture","companionService":{"loaded":true,"running":true,"pid":123},"originalService":{"loaded":false,"running":false},"runtime":{"confirmed":true,"agentReady":true,"observerReady":true,"backendKind":"accessibility-overlay"},"originalBundleModifiedByCompanion":false}"#.utf8)
        let service = CompanionService(script: URL(fileURLWithPath: "/fixture"), includesRuntime: true) { _, _ in
            if state.first() { return active }
            throw NSError(domain: "fixture unavailable", code: 2)
        }
        service.refresh()
        while service.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(service.agentReady)
        service.refresh()
        while service.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(service.status)
        XCTAssertFalse(service.canEnable); XCTAssertFalse(service.canDisable)
        XCTAssertNotNil(service.errorMessage)
    }
}
