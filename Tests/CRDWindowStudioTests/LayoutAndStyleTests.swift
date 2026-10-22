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
    @MainActor func testScreenMapMarkHasAMinimumSize() {
        let screen = CGRect(x: 0, y: 0, width: 120, height: 68)
        let dot = ScreenMap.mark(CGRect(x: 100, y: 3, width: 2.6, height: 2.6), in: screen)
        XCTAssertEqual(dot.size, CGSize(width: 6, height: 6))
        XCTAssertEqual(dot.midX, 101.3, accuracy: 0.01)
        XCTAssertTrue(screen.contains(dot))
        let corner = ScreenMap.mark(CGRect(x: 119, y: 67, width: 1, height: 1), in: screen)
        XCTAssertTrue(screen.contains(corner))
        XCTAssertEqual(ScreenMap.mark(CGRect(x: 10, y: 10, width: 27, height: 3), in: screen).size, CGSize(width: 27, height: 6))
    }

    /// The display map draws the saved display, or the first display when the saved one is not
    /// connected, as the helper and the real-size preview place the window. No real screen is read.
    @MainActor func testScreenMapUsesTheFirstDisplayWhenTheSavedOneIsNotConnected() {
        let first = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let second = (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1440, y: 40, width: 1920, height: 1015))
        XCTAssertEqual(ScreenMap.display([first, second], requested: 1).frame, second.frame)
        XCTAssertEqual(ScreenMap.display([first, second], requested: 1).visible, second.visible)
        let missing = ScreenMap.display([first, second], requested: 2)
        XCTAssertEqual(missing.frame, first.frame, "A saved third display that is not connected shows the first display")
        XCTAssertEqual(missing.visible, first.visible)
        XCTAssertEqual(ScreenMap.display([first, second], requested: 63).frame, first.frame)
        XCTAssertEqual(ScreenMap.display([], requested: 0).frame.size, CGSize(width: 1920, height: 1080))
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

    /// The preview's Stop pill uses the helper's metrics and red: the title plus 16 pt at each side
    /// and 7 pt above and below, white text on #D93036 above 4.5:1, and a faded fill when disabled.
    func testStopPillMatchesTheHelper() throws {
        let font = StopPill.font(size: 13)
        let text = ceil(("공유 중지" as NSString).size(withAttributes: [.font: font]).width)
        let size = StopPill.size(title: "공유 중지", font: 13)
        XCTAssertEqual(size.width, text + 32)
        XCTAssertEqual(size.height, ceil(font.ascender - font.descender) + 14)
        XCTAssertEqual(StopPill.minimumHeight(font: 13), ceil(font.ascender - font.descender) + 4)
        let red = try XCTUnwrap(StopPill.red.usingColorSpace(.sRGB))
        XCTAssertEqual(red.redComponent * 255, 0xD9, accuracy: 0.5)
        XCTAssertEqual(red.greenComponent * 255, 0x30, accuracy: 0.5)
        XCTAssertEqual(red.blueComponent * 255, 0x36, accuracy: 0.5)
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * channel(red.redComponent) + 0.7152 * channel(red.greenComponent) + 0.0722 * channel(red.blueComponent)
        XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, "White text on the pill")
        XCTAssertEqual(StopPill.fill(style: "red", enabled: false).alphaComponent, 0.38, accuracy: 0.001)
    }

    /// The grey style, resolved in light and dark: red text on a grey pill at 4.5:1 or more,
    /// pressed included, faded when disabled. The red style and an unknown value draw the red pill.
    @MainActor func testGrayStopPillKeepsItsTextReadableInBothLooks() throws {
        func resolved(_ color: NSColor, dark: Bool) throws -> NSColor {
            var result: NSColor?
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) }
            return try XCTUnwrap(result)
        }
        func luminance(_ c: NSColor) -> CGFloat {
            func channel(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        func ratio(_ a: NSColor, _ b: NSColor, dark: Bool) throws -> CGFloat {
            let x = luminance(try resolved(a, dark: dark)), y = luminance(try resolved(b, dark: dark))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for dark in [false, true] {
            for pressed in [false, true] {
                XCTAssertGreaterThanOrEqual(try ratio(StopPill.title(style: "gray", enabled: true, pressed: pressed),
                                                      StopPill.fill(style: "gray", enabled: true, pressed: pressed), dark: dark), 4.5, "dark \(dark) pressed \(pressed)")
            }
            let fill = try resolved(StopPill.fill(style: "gray", enabled: true), dark: dark), text = try resolved(StopPill.title(style: "gray", enabled: true), dark: dark)
            XCTAssertEqual(fill.redComponent, fill.blueComponent, accuracy: 0.03, "a neutral grey")
            XCTAssertGreaterThan(text.redComponent - text.greenComponent, 0.3, "red text")
            XCTAssertLessThan(try resolved(StopPill.fill(style: "gray", enabled: false), dark: dark).alphaComponent, 1)
            XCTAssertLessThan(try resolved(StopPill.title(style: "gray", enabled: false), dark: dark).alphaComponent, 0.6)
        }
        XCTAssertEqual(StopPill.fill(style: "red", enabled: true), StopPill.red)
        XCTAssertEqual(StopPill.fill(style: "unknown", enabled: true), StopPill.red)
        XCTAssertEqual(StopPill.title(style: "red", enabled: true), NSColor.white.withAlphaComponent(1))
    }

    /// stopStyle is an appearance setting: red by default, red or gray only, and saved and applied by presets.
    @MainActor func testStopStyleIsValidatedAndTravelsWithPresets() throws {
        let schema = try SettingsSchema.load()
        XCTAssertEqual(schema.defaults["stopStyle"], .string("red"))
        XCTAssertEqual(schema.choices["stopStyle"]?.map(\.id), ["red", "gray"])
        XCTAssertNoThrow(try schema.validateChanges(["stopStyle": .string("gray")]))
        XCTAssertThrowsError(try schema.validateChanges(["stopStyle": .string("blue")]))
        XCTAssertThrowsError(try schema.validateChanges(["stopStyle": .number(1)]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crd-stop-style-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), schema: schema)
        try repository.save(schema.defaults)
        let store = SettingsStore(repository: repository)
        XCTAssertTrue(PresetRepository(configuration: repository).storedKeys.contains("stopStyle"))
        store.set("stopStyle", .string("gray")); store.flush()
        XCTAssertEqual(try repository.load()["stopStyle"], .string("gray"))
        store.presets.reload()
        XCTAssertTrue(store.presets.saveCurrent(name: "Gray Stop", from: store))
        store.set("stopStyle", .string("red")); store.flush()
        XCTAssertTrue(store.presets.apply(try XCTUnwrap(store.presets.presets.first), to: store))
        XCTAssertEqual(try repository.load()["stopStyle"], .string("gray"))
    }

    /// The inline pill keeps its natural height when it fits, lowers to its minimum in a short
    /// window, and is hidden only when even that does not fit, as in the helper's Layout().
    func testInlineStopPillFitsShortWindows() throws {
        let title = L10n.text("공유 중지")
        let natural = StopPill.size(title: title, font: NSFont.systemFontSize)
        let bar = HelperOverlayLayout(values: try values([:]), stopTitle: title)
        XCTAssertTrue(bar.stop.visible)
        XCTAssertEqual(bar.stop.frame.size, natural)
        let short = HelperOverlayLayout(values: try values(["height": .number(26), "shape": .string("custom")]), stopTitle: title)
        XCTAssertTrue(short.stop.visible)
        XCTAssertEqual(short.stop.frame.height, 26)
        let tooShort = HelperOverlayLayout(values: try values(["height": .number(22), "shape": .string("custom")]), stopTitle: title)
        XCTAssertFalse(tooShort.stop.visible)
        // The compact shape narrows the pill's side padding to keep the dot beside the English label.
        let compact = try XCTUnwrap(try SettingsSchema.load().shapes.first { $0.id == "compact" })
        let english = HelperOverlayLayout(values: try values(compact.values), stopTitle: L10n.text("공유 중지", language: "en"))
        XCTAssertTrue(english.dot.visible && english.stop.visible)
        XCTAssertFalse(english.dot.frame.intersects(english.stop.frame))
    }

    /// The capsule drawing follows the helper's CapsuleLayout(): 6 pt around the pill, the dot
    /// 12 pt from the left end and 10 pt before the pill, centered, and a 120 pt press width.
    /// A hidden dot leaves no gap: the capsule gets the same 12 pt dot.
    func testStopCapsuleLayoutMatchesTheHelper() throws {
        let pill = StopPill.size(title: "공유 중지", font: NSFont.systemFontSize)
        let layout = StopCapsuleLayout(pill: pill, dot: 12)
        XCTAssertEqual(layout.pill.minY, 6)
        XCTAssertEqual(layout.size.height - layout.pill.maxY, 6)
        XCTAssertEqual(layout.size.width - layout.pill.maxX, 6)
        XCTAssertEqual(layout.dot.minX, 12)
        XCTAssertEqual(layout.pill.minX - layout.dot.maxX, 10)
        XCTAssertEqual(layout.dot.midY, layout.pill.midY)
        XCTAssertGreaterThanOrEqual(layout.size.width - (layout.pill.minX - 5), 120, "The press area is at least 120 pt wide")
        let hidden = StopCapsuleLayout(pill: pill, values: try values(["showDot": .bool(false)]))
        XCTAssertEqual(hidden.dot, layout.dot)
        XCTAssertEqual(hidden.pill, layout.pill)
        let long = StopCapsuleLayout(pill: CGSize(width: 900, height: pill.height), dot: 12)
        XCTAssertEqual(long.pill.width, 280, "A long label truncates inside the widest pill")
    }

    /// The capsule always shows its dot in front of Stop, so a double-click outside Stop can fold it back,
    /// as in the helper: the dot layout's own dot, min(dotDiameter, min(width, height)), while that dot is
    /// shown; a hidden dot and every other shape get a 12 pt dot.
    func testStopCapsuleAlwaysKeepsADotOutsideStop() throws {
        let pill = StopPill.size(title: L10n.text("공유 중지"), font: NSFont.systemFontSize)
        for shape in try SettingsSchema.load().shapes {
            for showDot in [true, false] {
                var changes = shape.values
                changes["showDot"] = .bool(showDot)
                let window = try values(changes)
                let layout = StopCapsuleLayout(pill: pill, values: window)
                let own = min(window["dotDiameter"]?.number ?? 0, min(window["width"]?.number ?? 0, window["height"]?.number ?? 0))
                let expected = window["layout"] == .string("dot") && showDot ? CGFloat(own) : 12
                XCTAssertEqual(layout.dot.width, expected, "\(shape.id), dot shown: \(showDot)")
                XCTAssertEqual(layout.dot.minX, 12, "\(shape.id), dot shown: \(showDot)")
                // A double-click within 6 pt of the Stop press area, which starts half the gap before
                // the pill, does nothing; the capsule's left end and the dot's center lie outside that zone.
                XCTAssertGreaterThan(layout.pill.minX - StopCapsuleLayout.dotGap / 2 - 6, layout.dot.midX, "\(shape.id), dot shown: \(showDot)")
            }
        }
        var large = try values(["layout": .string("dot"), "width": .number(30), "height": .number(20), "dotDiameter": .number(40)])
        XCTAssertEqual(StopCapsuleLayout(pill: pill, values: large).dot.width, 20, "The dot layout's dot never exceeds the window's shorter side")
        large["showDot"] = .bool(false)
        XCTAssertEqual(StopCapsuleLayout(pill: pill, values: large).dot.width, 12)
    }

    /// The double-click and its hide setting are described for every shape, in both languages,
    /// and the setting lives in the Behavior section rather than the status dot section.
    @MainActor func testDoubleClickTextDescribesEveryShape() {
        for language in ["ko", "en"] {
            let footer = L10n.text("공유 창의 아무 곳이나 끌어서 옮깁니다. 아무 곳이나 두 번 클릭하면 어떤 모양에서든 공유 중지 버튼이 나타나고, 버튼 밖을 다시 두 번 클릭하면 원래 모양으로 돌아갑니다. 위치나 크기를 잠가도 두 번 클릭은 작동합니다.", language: language)
            XCTAssertTrue(footer.contains(language == "ko" ? "어떤 모양에서든" : "on any shape"), language)
            for key in ["두 번 클릭하면 공유 중지 버튼이 나타나고, 다시 두 번 클릭하면 원래 모양으로 돌아갑니다", "두 번 클릭한 뒤",
                        "공유 중지 버튼 숨기기", "직접 숨길 때까지", "숨기기 전 대기 시간", "창 크기를 바꿔도 상태 점은 가운데에 유지됩니다."] {
                let text = L10n.text(key, language: language)
                XCTAssertFalse(language == "en" && text == key, "\(key) has an English translation")
                XCTAssertFalse(text.contains("상태 점으로 줄") || text.localizedCaseInsensitiveContains("shrink"), "\(key) describes the double-click as a status dot feature")
            }
        }
        XCTAssertEqual(BehaviorRows.footer, L10n.text("공유 창의 아무 곳이나 끌어서 옮깁니다. 아무 곳이나 두 번 클릭하면 어떤 모양에서든 공유 중지 버튼이 나타나고, 버튼 밖을 다시 두 번 클릭하면 원래 모양으로 돌아갑니다. 위치나 크기를 잠가도 두 번 클릭은 작동합니다."))
        XCTAssertEqual(ShrinkRows.titles, ["공유 중지 버튼 숨기기", "직접 숨길 때까지", "자동으로", "숨기기 전 대기 시간"].map { L10n.text($0) })
        XCTAssertEqual(DotRows.footer, L10n.text("창 크기를 바꿔도 상태 점은 가운데에 유지됩니다."))
    }

    /// One size and radius for every filled button; dark inactive and disabled fills differ clearly.
    @MainActor func testFilledButtonsShareOneSizeAndDistinctStates() {
        XCTAssertEqual(ProminentButtonStyle.cornerRadius, 6)
        XCTAssertEqual(ProminentButtonStyle.minimumHeight, 22)
        XCTAssertEqual(ProminentButtonStyle.neutralFill(enabled: true, dark: false), 0.12, "The light inactive fill is 12%")
        XCTAssertGreaterThanOrEqual(ProminentButtonStyle.neutralFill(enabled: true, dark: true) - ProminentButtonStyle.neutralFill(enabled: false, dark: true), 0.1)
    }
}
