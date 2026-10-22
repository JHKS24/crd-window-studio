import XCTest
@testable import CRDSettingsCore

/// Which changes a numeric field edit saves.
final class NumericEditTests: XCTestCase {
    private let bar: [String: ConfigValue] = ["shape": .string("bar"), "width": .number(440), "height": .number(48), "radius": .number(12), "x": .number(24)]

    func testUnchangedPresetFieldSavesNothingAndKeepsPreset() {
        for key in ["width", "height", "radius"] {
            XCTAssertNil(NumericEdit.changes(key: key, number: bar[key]!.number, current: bar), key)
        }
    }
    func testChangedPresetFieldClearsPreset() {
        XCTAssertEqual(NumericEdit.changes(key: "width", number: 441, current: bar), ["width": .number(441), "shape": .string("custom")])
    }
    func testOtherFieldsNeverTouchThePreset() {
        XCTAssertEqual(NumericEdit.changes(key: "x", number: 30, current: bar), ["x": .number(30)])
        XCTAssertNil(NumericEdit.changes(key: "x", number: 24, current: bar))
    }
}
