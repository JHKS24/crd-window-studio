import XCTest
@testable import CRDSettingsCore

/// Schema validation, migration and the configuration repository, on temporary files.
final class ConfigurationTests: XCTestCase {
    private func temporaryRepository() throws -> (ConfigurationRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: try .load()), directory)
    }
    func testDefaultsUseSystemAppearanceCenteredPlacementAndVisibleHandle() throws {
        let schema = try SettingsSchema.load()
        XCTAssertEqual(schema.defaults["mode"], .string("custom"))
        XCTAssertEqual(schema.defaults["appearance"], .string("system"))
        XCTAssertEqual(schema.defaults["background"], .string("system"))
        XCTAssertEqual(schema.defaults["foreground"], .string("system"))
        XCTAssertEqual(schema.defaults["accent"], .string("system"))
        XCTAssertEqual(schema.defaults["placement"], .string("center"))
        XCTAssertEqual(schema.defaults["showHandle"], .bool(true))
        XCTAssertNoThrow(try schema.validate(schema.defaults))
    }
    func testRestartRoundTripRestoresEntireShapeAndGeometry() throws {
        let (repository, directory) = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = repository.schema.defaults
        let card = try XCTUnwrap(repository.schema.shapes.first { $0.id == "card" })
        config.merge(card.values) { _, new in new }
        config["shape"] = .string("card")
        config["placement"] = .string("custom")
        config["x"] = .number(271)
        config["y"] = .number(193)
        config["accent"] = .string("purple")
        config["handlePosition"] = .string("top")
        config["handleSize"] = .number(18)
        try repository.save(config)
        let freshProcessEquivalent = ConfigurationRepository(url: repository.url, schema: try .load())
        XCTAssertEqual(try freshProcessEquivalent.load(), config)
    }
    func testInvalidInputCannotOverwriteSavedState() throws {
        let (repository, directory) = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try repository.save(repository.schema.defaults)
        let before = try Data(contentsOf: repository.url)
        var invalid = repository.schema.defaults
        invalid["width"] = .number(-100)
        XCTAssertThrowsError(try repository.save(invalid))
        XCTAssertEqual(try Data(contentsOf: repository.url), before)
        invalid = repository.schema.defaults
        invalid["width"] = .bool(true)
        XCTAssertThrowsError(try repository.save(invalid))
    }
    func testMalformedJSONIsReportedAndPreserved() throws {
        let (repository, directory) = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let malformed = Data("{user unfinished edit".utf8)
        try malformed.write(to: repository.url)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: repository.url), malformed)
    }
    func testInvalidExistingConfigurationRejectsSavePatchAndOrdinaryReset() throws {
        let (repository, directory) = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for contents in ["{unfinished", #"{"width":-1}"#, #"{"schema":999}"#] {
            let original = Data(contents.utf8)
            try original.write(to: repository.url)
            XCTAssertThrowsError(try repository.save(repository.schema.defaults))
            XCTAssertThrowsError(try repository.update(["width": .number(400), "schema": .number(1)]))
            XCTAssertThrowsError(try repository.resetToDefaults(requireExisting: true))
            XCTAssertEqual(try Data(contentsOf: repository.url), original)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("config-backup-") }.isEmpty)
        }
    }
    func testExplicitRecreationPreservesExactInvalidBytesBeforeReplacing() throws {
        let (repository, directory) = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data([0xff, 0x00, 0x7b, 0x22])
        try original.write(to: repository.url)
        let backup = try repository.recreateWithBackup()
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try repository.load(), repository.schema.defaults)
        XCTAssertEqual(backup.deletingLastPathComponent().path, directory.path)
    }
    func testMissingAndUnreadableFilesCannotBeRecreatedWithoutBackup() throws {
        let (repository, directory) = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try repository.recreateWithBackup())
        XCTAssertThrowsError(try repository.resetToDefaults(requireExisting: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url.path))
        try FileManager.default.createDirectory(at: repository.url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try repository.load())
        XCTAssertThrowsError(try repository.save(repository.schema.defaults))
        XCTAssertThrowsError(try repository.recreateWithBackup())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: repository.url.path).isEmpty)
    }
    func testAllShapePresetsAreValid() throws {
        let schema = try SettingsSchema.load()
        for preset in schema.shapes {
            var config = schema.defaults
            config.merge(preset.values) { _, new in new }
            config["shape"] = .string(preset.id)
            XCTAssertNoThrow(try schema.validate(config), preset.id)
        }
    }
    func testSemanticPaletteAndCustomColors() throws {
        let schema = try SettingsSchema.load()
        for choice in schema.choices["accent", default: []] {
            XCTAssertNoThrow(try schema.validate(["accent": .string(choice.id)]))
        }
        XCTAssertNoThrow(try schema.validate(["accent": .string("#617281")]))
        XCTAssertThrowsError(try schema.validate(["accent": .string("not-a-color")]))
    }
    func testDotColorInheritanceAndIndependentPalette() throws {
        let schema = try SettingsSchema.load()
        let inherited = try schema.validate(["accent": .string("green")])
        XCTAssertEqual(inherited["dotColor"], .string("accent"))
        for choice in schema.choices["accent", default: []] {
            XCTAssertNoThrow(try schema.validate(["dotColor": .string(choice.id)]), choice.id)
        }
        let independent = try schema.validate(["accent": .string("purple"), "dotColor": .string("#1aB2C3")])
        XCTAssertEqual(independent["dotColor"], .string("#1aB2C3"))
        XCTAssertEqual(independent["accent"], .string("purple"))
    }
    func testInvalidDotColorCannotOverwriteSavedConfiguration() throws {
        let (repository, directory) = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try repository.save(["accent": .string("green"), "dotColor": .string("#328AFF")])
        let before = try Data(contentsOf: repository.url)
        for invalid in ["not-a-color", "#12345", "#GGHHII", ""] {
            XCTAssertThrowsError(try repository.save(["dotColor": .string(invalid)]), invalid)
            XCTAssertEqual(try Data(contentsOf: repository.url), before)
        }
    }
    func testPartialOldConfigurationMigratesByDefaults() throws {
        let schema = try SettingsSchema.load()
        let old = try schema.validate(["schema": .number(1), "mode": .string("original"), "width": .number(360), "background": .string("#20242B")])
        XCTAssertEqual(old["width"], .number(360))
        XCTAssertEqual(old["mode"], .string("original")) // An explicit saved choice overrides the default.
        XCTAssertEqual(old["showHandle"], .bool(true))
        XCTAssertEqual(old["placement"], .string("center"))
    }
    /// A saved hidden mode loads as custom without an error, and the next write saves custom.
    func testSavedHiddenModeMigratesToCustom() throws {
        let schema = try SettingsSchema.load()
        XCTAssertEqual(schema.choices["mode"]?.map(\.id), ["custom", "original"])
        XCTAssertEqual(try schema.validate(["mode": .string("hidden")])["mode"], .string("custom"))
        XCTAssertEqual(SettingsSchema.migrated(["mode": .string("original")]), ["mode": .string("original")])
        XCTAssertThrowsError(try schema.validateChanges(["mode": .string("hidden")]), "Hidden is not a choice to save")
        let (repository, directory) = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: repository.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schema":1,"mode":"hidden","width":321}"#.utf8).write(to: repository.url)
        XCTAssertEqual(try repository.load()["mode"], .string("custom"))
        try repository.update(["height": .number(44)], requireExisting: true)
        let raw = try JSONDecoder().decode([String: ConfigValue].self, from: Data(contentsOf: repository.url))
        XCTAssertEqual(raw["mode"], .string("custom")); XCTAssertEqual(raw["width"], .number(321)); XCTAssertEqual(raw["height"], .number(44))
    }
    func testBackupPreservesPreviousConfig() throws {
        let (repository, directory) = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try repository.save(["mode": .string("custom")])
        let old = try Data(contentsOf: repository.url)
        let backup = try XCTUnwrap(repository.backup())
        try repository.save(repository.schema.defaults)
        XCTAssertEqual(try Data(contentsOf: backup), old)
    }
}
