import XCTest
import Darwin
@testable import CRDSettingsCore

/// presets.json beside a temporary config.json. Nothing touches the real support folder.
final class PresetRepositoryTests: XCTestCase {
    private var folder: URL!
    private var configuration: ConfigurationRepository!
    private var presets: PresetRepository!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("crd-presets-\(UUID().uuidString)")
        configuration = ConfigurationRepository(url: folder.appendingPathComponent("config.json"), schema: try SettingsSchema.load())
        presets = PresetRepository(configuration: configuration)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// The defaults with a small custom dot at a custom position.
    private var smallDot: [String: ConfigValue] {
        var values = configuration.schema.defaults
        let live: [String: ConfigValue] = ["layout": .string("dot"), "shape": .string("custom"), "width": .number(42), "height": .number(42),
                                           "radius": .number(21), "dotDiameter": .number(12), "draggable": .bool(true), "resizable": .bool(true),
                                           "placement": .string("custom"), "x": .number(1370), "y": .number(49), "stopRevealSeconds": .number(5),
                                           "showText": .bool(false), "showStopButton": .bool(false), "mode": .string("custom")]
        values.merge(live) { _, new in new }
        return values
    }

    func testMissingFileIsEmptyAndSaveWritesSchemaOneNextToConfig() throws {
        XCTAssertEqual(try presets.load(), .init(presets: [], movedAside: nil))
        XCTAssertEqual(presets.url, folder.appendingPathComponent("presets.json"))
        let saved = try presets.save(name: "  Small dot  ", values: smallDot).value
        XCTAssertEqual(saved.name, "Small dot")
        XCTAssertNil(saved.values["mode"]); XCTAssertNil(saved.values["enabled"]); XCTAssertNil(saved.values["loggingEnabled"]); XCTAssertNil(saved.values["schema"])
        XCTAssertEqual(saved.values["x"], .number(1370)); XCTAssertEqual(saved.values["draggable"], .bool(true))
        XCTAssertEqual(Set(saved.values.keys), Set(presets.storedKeys))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presets.url)) as? [String: Any])
        XCTAssertEqual(root["schema"] as? Int, 1)
        let entry = try XCTUnwrap((root["presets"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(entry.keys), ["id", "name", "values"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.url.path), "Saving a preset never writes config.json")
        XCTAssertEqual(try presets.load().presets, [saved])
    }

    func testRenameOverwriteDeleteAndApplyValues() throws {
        let first = try presets.save(name: "One", values: smallDot).value
        let second = try presets.save(name: "Two", values: configuration.schema.defaults).value
        try presets.rename(id: first.id, to: " Left ")
        XCTAssertEqual(try presets.load().presets.map(\.name), ["Left", "Two"])
        XCTAssertThrowsError(try presets.rename(id: second.id, to: "Left")) { XCTAssertEqual($0 as? PresetError, .duplicateName) }
        XCTAssertNoThrow(try presets.rename(id: first.id, to: "Left"), "Keeping its own name is not a duplicate")
        var moved = smallDot; moved["x"] = .number(10); moved["draggable"] = .bool(false)
        try presets.overwrite(id: second.id, values: moved)
        let applied = try presets.values(forPreset: second.id)
        XCTAssertEqual(applied["x"], .number(10)); XCTAssertEqual(applied["draggable"], .bool(false))
        XCTAssertNil(applied["mode"]); XCTAssertNil(applied["enabled"])
        // Applying is one validated merge that keeps mode and enabled as they are.
        var disabled = configuration.schema.defaults; disabled["enabled"] = .bool(false); disabled["mode"] = .string("original")
        try configuration.save(disabled)
        let merged = try configuration.update(applied)
        XCTAssertEqual(merged["mode"], .string("original")); XCTAssertEqual(merged["enabled"], .bool(false)); XCTAssertEqual(merged["x"], .number(10))
        XCTAssertTrue(PresetRepository.matches(try XCTUnwrap(presets.load().presets.last), merged))
        XCTAssertFalse(PresetRepository.matches(try XCTUnwrap(presets.load().presets.first), merged))
        try presets.delete(id: first.id)
        XCTAssertEqual(try presets.load().presets.map(\.id), [second.id])
        XCTAssertThrowsError(try presets.delete(id: first.id)) { XCTAssertEqual($0 as? PresetError, .notFound) }
        XCTAssertThrowsError(try presets.values(forPreset: first.id)) { XCTAssertEqual($0 as? PresetError, .notFound) }
    }

    func testNameAndCountLimits() throws {
        XCTAssertThrowsError(try presets.save(name: "   ", values: smallDot)) { XCTAssertEqual($0 as? PresetError, .invalidName) }
        XCTAssertThrowsError(try presets.save(name: String(repeating: "가", count: 41), values: smallDot)) { XCTAssertEqual($0 as? PresetError, .invalidName) }
        XCTAssertNoThrow(try presets.save(name: String(repeating: "가", count: 40), values: smallDot))
        for index in 1..<PresetRepository.countLimit { try presets.save(name: "Preset \(index)", values: smallDot) }
        XCTAssertEqual(try presets.load().presets.count, 20)
        XCTAssertThrowsError(try presets.save(name: "One more", values: smallDot)) { XCTAssertEqual($0 as? PresetError, .limitReached) }
        XCTAssertThrowsError(try presets.save(name: "Preset 1", values: smallDot))
        XCTAssertNotNil(PresetError.limitReached.errorDescription?.range(of: "20"))
        XCTAssertNotNil(PresetError.invalidName.errorDescription?.range(of: "40"))
    }

    func testValidationDropsUnknownAndExcludedKeysAndRejectsInvalidValues() throws {
        var values = smallDot; values["futureKey"] = .number(1)
        XCTAssertNil(try presets.validatedValues(values)["futureKey"])
        var invalid = smallDot; invalid["width"] = .number(-5)
        XCTAssertThrowsError(try presets.save(name: "Bad", values: invalid)) { XCTAssertEqual($0 as? PresetError, .invalidValues) }
        var wrongType = smallDot; wrongType["draggable"] = .number(1)
        XCTAssertThrowsError(try presets.save(name: "Bad", values: wrongType))
        XCTAssertThrowsError(try presets.validatedValues(["mode": .string("original"), "enabled": .bool(false)])) { XCTAssertEqual($0 as? PresetError, .invalidValues) }
        // Hand-edited entries: bad ones are skipped like the helper skips them; good ones keep only known keys.
        let file: [String: Any] = ["schema": 1, "presets": [
            ["id": "a", "name": " Kept ", "values": ["width": 300, "mode": "original", "futureKey": true, "showDot": false]],
            ["id": "b", "name": "Bad value", "values": ["width": -1]],
            ["id": "c", "name": "Bad type", "values": ["showDot": 1]],
            ["id": "d", "name": "", "values": ["width": 300]],
            ["id": "a", "name": "Duplicate id", "values": ["width": 300]],
            ["id": "e", "name": "Null value", "values": ["width": NSNull()]]
        ]]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: file).write(to: presets.url)
        let original = try Data(contentsOf: presets.url)
        let loaded = try presets.load()
        // A preset without stopStyle reads as the red Stop it was saved with; no other key is filled.
        XCTAssertEqual(loaded.presets, [Preset(id: "a", name: "Kept", values: ["width": .number(300), "showDot": .bool(false), "stopStyle": .string("red")])])
        // The partly unreadable file keeps its exact bytes aside before the readable presets are written back.
        XCTAssertTrue(loaded.partial)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(loaded.movedAside)), original)
        XCTAssertEqual(try presets.load(), .init(presets: loaded.presets, movedAside: nil), "Reported once")
    }

    func testCorruptFileIsMovedAsideReportedAndNeverBlocksConfiguration() throws {
        try configuration.save(smallDot)
        let configBytes = try Data(contentsOf: configuration.url)
        for corrupt in [Data("{bad".utf8), Data(#"{"schema":2,"presets":[]}"#.utf8), Data(#"{"schema":true,"presets":[]}"#.utf8), Data("[]".utf8)] {
            try corrupt.write(to: presets.url)
            let loaded = try presets.load()
            XCTAssertEqual(loaded.presets, [])
            let aside = try XCTUnwrap(loaded.movedAside)
            XCTAssertTrue(aside.lastPathComponent.hasPrefix("presets-corrupt-"))
            XCTAssertEqual(aside.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path)
            XCTAssertEqual(try Data(contentsOf: aside), corrupt, "The unreadable bytes are kept")
            XCTAssertFalse(FileManager.default.fileExists(atPath: presets.url.path))
            XCTAssertEqual(try configuration.load(), smallDot)
            XCTAssertEqual(try Data(contentsOf: configuration.url), configBytes)
        }
        // After a corrupt file a new save starts a clean list.
        try Data("{bad".utf8).write(to: presets.url)
        let fresh = try presets.save(name: "Fresh", values: smallDot)
        XCTAssertEqual(fresh.value.name, "Fresh")
        XCTAssertNotNil(fresh.movedAside, "Corruption found by a save is reported through the change")
        XCTAssertFalse(fresh.partial)
        XCTAssertEqual(try presets.load().presets.map(\.name), ["Fresh"])
    }

    func testWritesWaitForTheSharedConfigLock() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(configuration.url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let repository = presets!, values = smallDot
        let finished = expectation(description: "save after unlock")
        let saved = LockedFlag()
        DispatchQueue.global().async {
            _ = try? repository.save(name: "Waits", values: values)
            saved.set(); finished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(saved.value, "The save must wait for config.json.lock")
        flock(fd, LOCK_UN); close(fd)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(try presets.load().presets.map(\.name), ["Waits"])
    }

    func testAutoShrinkAllowsZeroAndKeepsTheDefault() throws {
        let schema = configuration.schema
        XCTAssertEqual(schema.numericLimits["stopRevealSeconds"], [0, 30])
        XCTAssertEqual(schema.defaults["stopRevealSeconds"], .number(5))
        XCTAssertNoThrow(try schema.validateChanges(["stopRevealSeconds": .number(0)]))
        XCTAssertThrowsError(try schema.validateChanges(["stopRevealSeconds": .number(-1)]))
        XCTAssertThrowsError(try schema.validateChanges(["stopRevealSeconds": .number(31)]))
    }
    func testPartlyCorruptFileFoundByAMutationIsBackedUpAndReported() throws {
        let kept = try presets.save(name: "Kept", values: smallDot).value
        // Another writer leaves an entry this version cannot read next to the valid one.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presets.url)) as? [String: Any])
        var entries = try XCTUnwrap(root["presets"] as? [[String: Any]])
        entries.append(["id": "bad", "name": "Small dot", "values": ["width": -1]])
        root["presets"] = entries
        try JSONSerialization.data(withJSONObject: root).write(to: presets.url)
        let original = try Data(contentsOf: presets.url)
        let change = try presets.rename(id: kept.id, to: "Renamed")
        XCTAssertTrue(change.partial)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(change.movedAside)), original, "The exact bytes survive the rewrite")
        XCTAssertEqual(try presets.load().presets.map(\.name), ["Renamed"])
        XCTAssertNil(try presets.load().movedAside)
    }

    func testConfigBackupResetAndRecreateCopyPresetsWithTheSameIdentifier() throws {
        try configuration.save(smallDot)
        let backup = try XCTUnwrap(try configuration.backup())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("presets.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("presets-backup-") }, [], "No presets file is fine")
        try presets.save(name: "Small dot", values: smallDot)
        let presetBytes = try Data(contentsOf: presets.url)
        for make in [{ try self.configuration.backup() }, { try self.configuration.resetToDefaults(requireExisting: true) }] as [() throws -> URL?] {
            let made = try XCTUnwrap(try make())
            let identifier = made.lastPathComponent.replacingOccurrences(of: "config-backup-", with: "").replacingOccurrences(of: ".json", with: "")
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("presets-backup-\(identifier).json")), presetBytes)
            XCTAssertEqual(try Data(contentsOf: presets.url), presetBytes, "The live presets stay as they are")
        }
        try Data("{ not json".utf8).write(to: configuration.url)
        let recreated = try configuration.recreateWithBackup()
        let identifier = recreated.lastPathComponent.replacingOccurrences(of: "config-backup-", with: "").replacingOccurrences(of: ".json", with: "")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("presets-backup-\(identifier).json")), presetBytes)
        XCTAssertNotEqual(backup, recreated)
    }

    func testReachablePlacementKeepsPresetsOnTheDisplayTheyUse() {
        let frames = [CGRect(x: 0, y: 25, width: 1440, height: 875), CGRect(x: 1440, y: 0, width: 800, height: 600)]
        var far = smallDot; far["constrainToScreen"] = .bool(false); far["x"] = .number(60000); far["y"] = .number(49)
        let clamped = PresetRepository.reachablePlacement(far, visibleFrames: frames)
        XCTAssertEqual(clamped["x"], .number(1440 - 42)); XCTAssertEqual(clamped["y"], .number(49)); XCTAssertEqual(clamped["placement"], .string("custom"))
        XCTAssertNil(clamped["screen"])
        var missing = far; missing["screen"] = .number(63)
        XCTAssertEqual(PresetRepository.reachablePlacement(missing, visibleFrames: frames)["screen"], .number(0))
        var second = far; second["screen"] = .number(1)
        XCTAssertEqual(PresetRepository.reachablePlacement(second, visibleFrames: frames)["x"], .number(800 - 42), "The smaller display bounds it")
        var top = smallDot; top["placement"] = .string("top"); top["edgeInset"] = .number(5000)
        let topChanges = PresetRepository.reachablePlacement(top, visibleFrames: frames)
        XCTAssertEqual(topChanges["y"], .number(875 - 42)); XCTAssertEqual(topChanges["placement"], .string("custom"))
        var fits = smallDot; fits["x"] = .number(1370); fits["y"] = .number(49)
        XCTAssertEqual(PresetRepository.reachablePlacement(fits, visibleFrames: frames), [:], "A position that fits is left alone")
        XCTAssertEqual(PresetRepository.reachablePlacement(fits, visibleFrames: []), [:])
    }
}

/// A thread-safe flag for the lock test.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
