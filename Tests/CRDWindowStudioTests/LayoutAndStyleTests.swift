import XCTest
import CRDSettingsCore
@testable import CRDWindowStudio

/// The rules behind the settings pages' drawings, checked without rendering: the saving-paused
/// status, the preview's save note, the display map, the helper layout and the filled buttons.
final class LayoutAndStyleTests: XCTestCase {
    /// The schema defaults with `changes` applied.
    private func values(_ changes: [String: ConfigValue]) throws -> [String: ConfigValue] {
        var values = try SettingsSchema.load().defaults
        values.merge(changes) { $1 }
        return values
    }

    /// An unreadable settings file pauses saving; the helper keeps its last settings, so it is not a helper problem.
    @MainActor func testUnreadableSettingsFileShowsSavingPaused() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crd-unreadable-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        try Data("{ not json".utf8).write(to: url)
        let store = SettingsStore(repository: ConfigurationRepository(url: url, schema: try .load()), inspectHost: {
            HostInspection(version: "155.0.8059", patchInstalled: true, running: true, windowObserved: true, detail: "fixture")
        })
        store.refreshHost(); while !store.hostChecked { try await Task.sleep(for: .milliseconds(10)) }
        let data = FixtureState.running.statusData
        let companion = CompanionService(script: URL(fileURLWithPath: "/fixture/companionctl.py"), includesRuntime: true) { _, _ in data }
        companion.refresh(); while companion.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.loadError)
        let status = StudioStatus.make(companion: companion, store: store)
        XCTAssertEqual(status.kind, .savingPaused)
        XCTAssertEqual(status.title, L10n.text("설정 저장 멈춤"))
        XCTAssertNil(status.action, "The banner holds the recovery actions")
        XCTAssertFalse(status.needsAttention)
    }

    /// The preview's save note shows unless both locks are on.
    func testPreviewNoteHidesOnlyWithBothLocks() {
        XCTAssertTrue(PreviewWindowNote.shows([:]))
        XCTAssertTrue(PreviewWindowNote.shows(["draggable": .bool(false), "resizable": .bool(true)]))
        XCTAssertTrue(PreviewWindowNote.shows(["draggable": .bool(true), "resizable": .bool(false)]))
        XCTAssertFalse(PreviewWindowNote.shows(["draggable": .bool(false), "resizable": .bool(false)]))
    }

    /// The display map's window mark is never smaller than 6 x 6 pt and stays on the screen drawing.
    func testScreenMapMarkHasAMinimumSize() {
        let screen = CGRect(x: 0, y: 0, width: 120, height: 68)
        let dot = ScreenMap.mark(CGRect(x: 100, y: 3, width: 2.6, height: 2.6), in: screen)
        XCTAssertEqual(dot.size, CGSize(width: 6, height: 6))
        XCTAssertEqual(dot.midX, 101.3, accuracy: 0.01)
        XCTAssertTrue(screen.contains(dot))
        let corner = ScreenMap.mark(CGRect(x: 119, y: 67, width: 1, height: 1), in: screen)
        XCTAssertTrue(screen.contains(corner))
        XCTAssertEqual(ScreenMap.mark(CGRect(x: 10, y: 10, width: 27, height: 3), in: screen).size, CGSize(width: 27, height: 6))
    }

    /// The app's drawing follows the helper: a full capsule end insets the grip 3 pt more
    /// (the helper's self-test expects the same 10 and 370), and the card's top handle keeps every item.
    func testGripAndCardLayoutMatchTheHelper() throws {
        let pill = HelperOverlayLayout(values: try values(["width": .number(380), "height": .number(48), "radius": .number(24)]), stopTitle: L10n.text("공유 중지"))
        XCTAssertTrue(pill.resize.visible)
        XCTAssertEqual(pill.resize.frame.minY, 10); XCTAssertEqual(pill.resize.frame.maxX, 370)
        let bar = HelperOverlayLayout(values: try values([:]), stopTitle: L10n.text("공유 중지"))
        XCTAssertEqual(bar.resize.frame.minY, 4, "A rounded corner that is not a full end keeps the plain inset")
        let schema = try SettingsSchema.load()
        let card = try XCTUnwrap(schema.shapes.first { $0.id == "card" })
        XCTAssertEqual(card.values["handlePosition"], .string("top"))
        let layout = HelperOverlayLayout(values: try values(card.values), stopTitle: L10n.text("공유 중지"))
        XCTAssertTrue(layout.handle.visible && layout.dot.visible && layout.label.visible && layout.stop.visible)
        XCTAssertLessThanOrEqual(layout.dot.frame.maxY, layout.handle.frame.minY, "The dot sits below the top handle")
        for id in ["bar", "pill", "compact"] {
            XCTAssertEqual(schema.shapes.first { $0.id == id }?.values["handlePosition"], .string("leading"), id)
        }
    }

    /// One size and radius for every filled button; dark inactive and disabled fills differ clearly.
    func testFilledButtonsShareOneSizeAndDistinctStates() {
        XCTAssertEqual(ProminentButtonStyle.cornerRadius, 6)
        XCTAssertEqual(ProminentButtonStyle.minimumHeight, 22)
        XCTAssertEqual(ProminentButtonStyle.neutralFill(enabled: true, dark: false), 0.12, "The light inactive fill is 12%")
        XCTAssertGreaterThanOrEqual(ProminentButtonStyle.neutralFill(enabled: true, dark: true) - ProminentButtonStyle.neutralFill(enabled: false, dark: true), 0.1)
    }
}
