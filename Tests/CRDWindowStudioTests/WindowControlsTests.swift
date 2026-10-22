import XCTest
import CRDSettingsCore
@testable import CRDWindowStudio

/// Locks, auto-shrink, presets in the settings app, and the preview's system-resize guard.
final class WindowControlsTests: XCTestCase {
    /// A store over a temporary configuration in original mode with the switch off.
    @MainActor private func makeStore() throws -> (SettingsStore, ConfigurationRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crd-window-controls-\(UUID().uuidString)")
        let repository = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: try .load())
        var initial = repository.schema.defaults
        initial["mode"] = .string("original"); initial["enabled"] = .bool(false)
        try repository.save(initial)
        return (SettingsStore(repository: repository), repository, directory)
    }

    /// There are two display modes: custom and original.
    func testDisplayModesAreCustomAndOriginalOnly() throws {
        XCTAssertEqual(StudioMode.order, ["custom", "original"])
        XCTAssertEqual(try SettingsSchema.load().choices["mode"]?.map(\.id), ["custom", "original"])
        XCTAssertEqual(StudioMode.title("custom"), L10n.text("꾸민 창"))
        XCTAssertEqual(StudioMode.title("original"), L10n.text("원래 공유 창"))
    }

    /// A saved hidden mode opens as custom with no banner, no error and saving on; the next save writes custom.
    @MainActor func testSavedHiddenModeOpensAsCustomAndTheNextSaveWritesCustom() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crd-hidden-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"schema":1,"mode":"hidden","enabled":true,"width":321}"#.utf8).write(to: url)
        let repository = ConfigurationRepository(url: url, schema: try .load())
        let store = SettingsStore(repository: repository)
        XCTAssertNil(store.loadError); XCTAssertNil(store.errorMessage); XCTAssertTrue(store.canSave)
        XCTAssertEqual(store.string("mode"), "custom"); XCTAssertEqual(store.number("width"), 321)
        XCTAssertTrue(StudioMode.customInEffect(store))
        store.set("height", .number(44)); store.flush()
        let saved = try JSONDecoder().decode([String: ConfigValue].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved["mode"], .string("custom")); XCTAssertEqual(saved["height"], .number(44)); XCTAssertEqual(saved["width"], .number(321))
        XCTAssertNil(store.errorMessage)
    }

    func testLockTogglesMapToTheExistingKeysInverted() {
        XCTAssertEqual(WindowLock.position.key, "draggable")
        XCTAssertEqual(WindowLock.size.key, "resizable")
        XCTAssertEqual(WindowLock.position.change(locked: true), ["draggable": .bool(false)])
        XCTAssertEqual(WindowLock.size.change(locked: false), ["resizable": .bool(true)])
        XCTAssertTrue(WindowLock.position.isLocked(["draggable": .bool(false)]))
        XCTAssertFalse(WindowLock.size.isLocked(["resizable": .bool(true)]))
        XCTAssertFalse(WindowLock.position.isLocked([:]), "A missing key reads as the unlocked default")
        XCTAssertEqual(WindowLock.position.title, L10n.text("위치 잠금"))
        XCTAssertEqual(WindowLock.size.title, L10n.text("크기 잠금"))
    }

    @MainActor func testLockToggleWritesOnlyTheGuardedKey() throws {
        let (store, repository, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.update(WindowLock.position.change(locked: true)); store.flush()
        let saved = try repository.load()
        XCTAssertEqual(saved["draggable"], .bool(false)); XCTAssertEqual(saved["resizable"], .bool(true))
        XCTAssertEqual(saved["mode"], .string("original")); XCTAssertEqual(saved["enabled"], .bool(false))
    }

    @MainActor func testAutoShrinkZeroIsAcceptedBySettingsStore() throws {
        let (store, repository, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.set("stopRevealSeconds", .number(0)); store.flush()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try repository.load()["stopRevealSeconds"], .number(0))
        store.set("stopRevealSeconds", .number(-1))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.values["stopRevealSeconds"], .number(0))
    }

    func testShrinkWaysMapToTheSingleKey() {
        XCTAssertFalse(ShrinkSetting.isAutomatic(.number(0)), "0 is until I shrink it")
        XCTAssertTrue(ShrinkSetting.isAutomatic(.number(5)))
        XCTAssertEqual(ShrinkSetting.automaticSeconds(.number(1)), 1)
        XCTAssertEqual(ShrinkSetting.automaticSeconds(.number(30)), 30)
        XCTAssertNil(ShrinkSetting.automaticSeconds(.number(31)))
        XCTAssertNil(ShrinkSetting.automaticSeconds(nil))
        XCTAssertEqual(ShrinkSetting.seconds(current: .number(0), remembered: nil), 5, "No remembered value falls back to 5")
        XCTAssertEqual(ShrinkSetting.seconds(current: .number(0), remembered: 12), 12)
        XCTAssertEqual(ShrinkSetting.seconds(current: .number(0), remembered: 0), 5, "A remembered 0 is not an automatic value")
        XCTAssertEqual(ShrinkSetting.seconds(current: .number(8), remembered: 12), 8, "The current automatic value wins")
        XCTAssertEqual(ShrinkSetting.automaticRange, 1...30)
    }

    @MainActor func testShrinkChoiceStoresZeroAndRestoresTheRememberedSeconds() throws {
        let (store, repository, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(store.shrinksAutomatically, "A saved value of 5 reads as Automatically, 5 seconds")
        XCTAssertEqual(store.automaticShrinkSeconds, 5)
        store.set(ShrinkSetting.key, .number(12)); store.flush()
        store.setShrinksAutomatically(false); store.flush()
        XCTAssertFalse(store.shrinksAutomatically)
        XCTAssertEqual(try repository.load()[ShrinkSetting.key], .number(0))
        XCTAssertEqual(store.automaticShrinkSeconds, 12, "The seconds field is prefilled with the last automatic value")
        store.setShrinksAutomatically(true); store.flush()
        XCTAssertEqual(try repository.load()[ShrinkSetting.key], .number(12))
        // Across launches the value comes from the app's own defaults; without any, 5.
        let suite = "local.crdwindow.studio.test.\(UUID().uuidString)"
        let memory = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { memory.removePersistentDomain(forName: suite) }
        try repository.update([ShrinkSetting.key: .number(9)])
        _ = SettingsStore(repository: repository, shrinkMemory: memory)
        try repository.update([ShrinkSetting.key: .number(0)])
        XCTAssertEqual(SettingsStore(repository: repository, shrinkMemory: memory).automaticShrinkSeconds, 9)
        XCTAssertEqual(SettingsStore(repository: repository).automaticShrinkSeconds, 5)
    }

    // The position fits any display: applying clamps to the real screen.
    @MainActor func testPresetStoreSavesAppliesAndNeverChangesModeOrEnabled() throws {
        let (store, repository, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let presets = store.presets
        presets.reload()
        XCTAssertEqual(presets.presets, [])
        store.update(["layout": .string("dot"), "width": .number(42), "height": .number(42), "x": .number(100), "y": .number(49), "placement": .string("custom")])
        XCTAssertTrue(presets.saveCurrent(name: "Small dot", from: store))
        let preset = try XCTUnwrap(presets.presets.first)
        XCTAssertTrue(presets.isCurrent(preset, in: store))
        store.update(["layout": .string("row"), "width": .number(440), "height": .number(48), "placement": .string("center")]); store.flush()
        XCTAssertFalse(presets.isCurrent(preset, in: store))
        // Mode and enabled change elsewhere; applying keeps them.
        try repository.update(["mode": .string("original"), "enabled": .bool(true)]); store.reload()
        XCTAssertTrue(presets.apply(preset, to: store))
        let saved = try repository.load()
        XCTAssertEqual(saved["layout"], .string("dot")); XCTAssertEqual(saved["x"], .number(100)); XCTAssertEqual(saved["placement"], .string("custom"))
        XCTAssertEqual(saved["mode"], .string("original")); XCTAssertEqual(saved["enabled"], .bool(true))
        XCTAssertTrue(presets.isCurrent(preset, in: store))
        // Rename, overwrite and delete reload the list; errors become a notice instead of throwing.
        XCTAssertTrue(presets.rename(preset, to: "Left"))
        XCTAssertEqual(presets.presets.map(\.name), ["Left"])
        XCTAssertFalse(presets.saveCurrent(name: "Left", from: store))
        XCTAssertEqual(presets.notice, PresetError.duplicateName.errorDescription)
        presets.notice = nil
        store.update(["x": .number(5)])
        XCTAssertTrue(presets.overwrite(try XCTUnwrap(presets.presets.first), from: store))
        XCTAssertEqual(presets.presets.first?.values["x"], .number(5))
        XCTAssertTrue(presets.delete(try XCTUnwrap(presets.presets.first)))
        XCTAssertEqual(presets.presets, [])
    }

    @MainActor func testSettingsPresetApplySavesAReachablePosition() throws {
        let (store, repository, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = store.screens.map(\.visibleFrame)
        try XCTSkipIf(frames.isEmpty, "No display to measure")
        let far: [String: ConfigValue] = ["constrainToScreen": .bool(false), "placement": .string("custom"), "x": .number(60000), "y": .number(49),
                                          "width": .number(42), "height": .number(42), "screen": .number(63)]
        store.update(far); XCTAssertTrue(store.presets.saveCurrent(name: "Far", from: store))
        store.update(["x": .number(0), "screen": .number(0)]); store.flush()
        XCTAssertTrue(store.presets.apply(try XCTUnwrap(store.presets.presets.first), to: store))
        let saved = try repository.load()
        XCTAssertEqual(saved["screen"], .number(0))
        XCTAssertEqual(saved["x"], .number(frames[0].width - 42), "The reachable position is in the same write")
        XCTAssertEqual(saved["mode"], .string("original")); XCTAssertEqual(saved["enabled"], .bool(false))
    }

    @MainActor func testCorruptionFoundDuringSaveIsReportedOnce() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.presets.reload()
        try Data("{bad".utf8).write(to: directory.appendingPathComponent("presets.json"))
        XCTAssertTrue(store.presets.saveCurrent(name: "After corruption", from: store))
        XCTAssertEqual(store.presets.notice, L10n.text("프리셋 파일을 읽을 수 없어 기존 파일을 따로 보관했습니다. 필요한 프리셋을 다시 저장하세요."))
        store.presets.notice = nil; store.presets.reload()
        XCTAssertNil(store.presets.notice)
        XCTAssertEqual(store.presets.presets.map(\.name), ["After corruption"])
    }

    @MainActor func testPartlyUnreadablePresetsFileKeepsReadablePresetsAndSaysSoOnce() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file: [String: Any] = ["schema": 1, "presets": [["id": "a", "name": "Kept", "values": ["width": 300]], ["id": "b", "name": "Bad", "values": ["width": -1]]]]
        try JSONSerialization.data(withJSONObject: file).write(to: directory.appendingPathComponent("presets.json"))
        store.presets.reload()
        XCTAssertEqual(store.presets.presets.map(\.name), ["Kept"])
        XCTAssertEqual(store.presets.notice, L10n.text("프리셋 파일의 일부를 읽을 수 없어 기존 파일을 따로 보관하고, 정상적인 프리셋만 불러왔습니다."))
        store.presets.notice = nil; store.presets.reload()
        XCTAssertNil(store.presets.notice)
    }

    @MainActor func testUnreadablePresetsFileIsReportedOnceAndConfigStillLoads() throws {
        let (store, repository, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{bad".utf8).write(to: directory.appendingPathComponent("presets.json"))
        store.presets.reload()
        XCTAssertEqual(store.presets.presets, [])
        XCTAssertEqual(store.presets.notice, L10n.text("프리셋 파일을 읽을 수 없어 기존 파일을 따로 보관했습니다. 필요한 프리셋을 다시 저장하세요."))
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.values, try repository.load())
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("presets-corrupt-") })
        store.presets.notice = nil; store.presets.reload()
        XCTAssertNil(store.presets.notice, "The moved file is reported once")
    }

    /// A full preset saved before the Stop style existed loads as the red Stop: it does not match a
    /// gray window, applying it sets red, and the read sets nothing aside. An explicit gray preset keeps gray.
    @MainActor func testPresetWithoutStopStyleLoadsAndAppliesAsRed() throws {
        let (store, repository, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let presets = PresetRepository(configuration: repository)
        var older: [String: Any] = [:]
        for key in presets.storedKeys where key != "stopStyle" {
            switch store.values[key] {
            case .string(let v): older[key] = v
            case .number(let v): older[key] = v
            case .bool(let v): older[key] = v
            default: break
            }
        }
        var gray = older; gray["stopStyle"] = "gray"
        let file: [String: Any] = ["schema": 1, "presets": [["id": "older", "name": "Before styles", "values": older], ["id": "gray", "name": "Gray", "values": gray]]]
        let url = directory.appendingPathComponent("presets.json")
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let bytes = try Data(contentsOf: url)
        store.set("stopStyle", .string("gray")); store.flush()
        store.presets.reload()
        XCTAssertNil(store.presets.notice)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "the read writes nothing back")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("presets-corrupt-") })
        let olderPreset = try XCTUnwrap(store.presets.presets.first { $0.id == "older" })
        let grayPreset = try XCTUnwrap(store.presets.presets.first { $0.id == "gray" })
        XCTAssertEqual(olderPreset.values["stopStyle"], .string("red"))
        XCTAssertEqual(olderPreset.values.count, older.count + 1, "no other key is filled")
        XCTAssertEqual(grayPreset.values["stopStyle"], .string("gray"))
        XCTAssertFalse(store.presets.isCurrent(olderPreset, in: store))
        XCTAssertTrue(store.presets.isCurrent(grayPreset, in: store))
        XCTAssertTrue(store.presets.apply(olderPreset, to: store))
        var saved = try repository.load()
        XCTAssertEqual(saved["stopStyle"], .string("red"))
        XCTAssertEqual(saved["mode"], .string("original")); XCTAssertEqual(saved["enabled"], .bool(false))
        XCTAssertTrue(store.presets.apply(grayPreset, to: store))
        saved = try repository.load()
        XCTAssertEqual(saved["stopStyle"], .string("gray"))
        XCTAssertEqual(saved["mode"], .string("original")); XCTAssertEqual(saved["enabled"], .bool(false))
        XCTAssertNil(store.presets.notice)
    }

    /// The first read waits for the configuration lock off the main thread: the main thread keeps
    /// running, a second call joins the same read, and the result and its notice arrive once.
    @MainActor func testFirstPresetReadWaitsForTheLockOffTheMainThread() async throws {
        let (store, repository, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file: [String: Any] = ["schema": 1, "presets": [["id": "a", "name": "Kept", "values": ["width": 300]], ["id": "b", "name": "Bad", "values": ["width": -1]]]]
        try JSONSerialization.data(withJSONObject: file).write(to: directory.appendingPathComponent("presets.json"))
        let lock = open(repository.url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertTrue(lock >= 0 && flock(lock, LOCK_EX) == 0)
        let presets = store.presets
        presets.loadIfNeeded(); presets.loadIfNeeded()
        XCTAssertTrue(presets.loading)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(presets.loading, "the read is still waiting for the lock")
        XCTAssertFalse(presets.loaded)
        XCTAssertEqual(presets.presets, [])
        flock(lock, LOCK_UN); close(lock)
        let deadline = Date().addingTimeInterval(5)
        while !presets.loaded && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(presets.loaded); XCTAssertFalse(presets.loading)
        XCTAssertEqual(presets.presets.map(\.name), ["Kept"])
        XCTAssertEqual(presets.notice, L10n.text("프리셋 파일의 일부를 읽을 수 없어 기존 파일을 따로 보관하고, 정상적인 프리셋만 불러왔습니다."))
        let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("presets-corrupt-") }
        XCTAssertEqual(copies.count, 1, "both calls share one read")
        presets.notice = nil
        presets.loadIfNeeded()
        XCTAssertFalse(presets.loading, "a loaded list is not read again")
    }

    func testPreviewSavesOnlyTheUsersOwnMovesAndResizes() {
        XCTAssertTrue(PreviewWindowController.isUserGesture(liveResize: true, pressStartedInWindow: false, buttonDown: true), "An edge drag")
        XCTAssertTrue(PreviewWindowController.isUserGesture(liveResize: false, pressStartedInWindow: true, buttonDown: true), "A title-bar drag")
        XCTAssertFalse(PreviewWindowController.isUserGesture(liveResize: false, pressStartedInWindow: false, buttonDown: false), "A same-size system or programmatic move")
        XCTAssertFalse(PreviewWindowController.isUserGesture(liveResize: false, pressStartedInWindow: true, buttonDown: false), "Tiling after the drop")
        XCTAssertFalse(PreviewWindowController.isUserGesture(liveResize: false, pressStartedInWindow: false, buttonDown: true), "A press elsewhere")
    }
}
