import XCTest
@testable import CRDSettingsCore

/// Language selection, catalog coverage and formatting.
final class LocalizationTests: XCTestCase {
    func testLanguageSelectionUsesSupportedAppLanguages() {
        XCTAssertEqual(L10n.languageCode(for: ["ko-KR", "en-US"]), "ko")
        XCTAssertEqual(L10n.languageCode(for: ["en-GB", "ko-KR"]), "en")
        XCTAssertEqual(L10n.languageCode(for: ["fr-FR"]), "en")
    }
    func testKoreanFormattingPreservesAllInterpolatedArguments() {
        XCTAssertEqual(L10n.format("%@ 값은 %@~%@ 사이로 지정하세요.", arguments: ["width", 1, 16384], language: "ko"),
                       "width 값은 1~16384 사이로 지정하세요.")
        XCTAssertEqual(L10n.format("%@ · %@ × %@ pt", arguments: ["미리보기", 40, 40], language: "ko"),
                       "미리보기 · 40 × 40 pt")
    }
    func testCustomUserTextIsPreservedAndLegacyDefaultIsLocalized() {
        XCTAssertEqual(L10n.buttonTitle("내 버튼 이름", language: "ko"), "내 버튼 이름")
        XCTAssertEqual(L10n.buttonTitle("", language: "ko"), "공유 중지")
        XCTAssertEqual(L10n.buttonTitle("공유 중지", language: "ko"), "공유 중지")
        XCTAssertEqual(L10n.text("unregistered technical value", language: "ko"), "unregistered technical value")
    }
    /// The packaged catalog for `language`.
    private func catalog(_ language: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/CRDSettingsCore/Resources/Localization/\(language).json")
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }
    func testEveryEnglishCatalogEntryLoadsFromPackagedResources() throws {
        let english = try catalog("en")
        let korean = try catalog("ko")
        XCTAssertEqual(Set(english.keys), Set(korean.keys))
        XCTAssertNotEqual(english["표시"], korean["표시"])
        for (key, value) in english {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(L10n.text(key, language: "en"), value, key)
        }
    }
    func testEnglishFormattingAndLegacyButtonDefaultPreserveUserText() throws {
        let english = try catalog("en")
        XCTAssertEqual(L10n.buttonTitle("공유 중지", language: "en"), english["공유 중지"])
        XCTAssertEqual(L10n.buttonTitle("", language: "en"), english["공유 중지"])
        XCTAssertEqual(L10n.buttonTitle("내가 정한 문구", language: "en"), "내가 정한 문구")
        let formatted = L10n.format("%@ 값은 %@~%@ 사이로 지정하세요.", arguments: ["VALUE_A", "VALUE_B", "VALUE_C"], language: "en")
        for argument in ["VALUE_A", "VALUE_B", "VALUE_C"] { XCTAssertTrue(formatted.contains(argument), argument) }
        XCTAssertFalse(formatted.contains("%@"))
    }

}
