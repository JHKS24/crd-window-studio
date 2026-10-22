import Foundation

/// String lookup for the app. The Korean source strings are the keys, shared with the native
/// helper. Catalogs use printf `%@` arguments, so Swift and NSString use the same translations.
public enum L10n {
    /// Picks "ko" or "en" from the preferred languages; English is the fallback.
    public static func languageCode(for preferredLanguages: [String]) -> String {
        Bundle.preferredLocalizations(from: ["en", "ko"], forPreferences: preferredLanguages).first == "ko" ? "ko" : "en"
    }
    public static var languageCode: String { languageCode(for: Locale.preferredLanguages) }
    private static let catalogs: [String: [String: String]] = {
        var result: [String: [String: String]] = [:]
        for language in ["ko", "en"] {
            let url = Bundle.main.url(forResource: language, withExtension: "json", subdirectory: "Localization")
                ?? Bundle.module.url(forResource: language, withExtension: "json", subdirectory: "Localization")
            if let url, let data = try? Data(contentsOf: url),
               let catalog = try? JSONDecoder().decode([String: String].self, from: data) { result[language] = catalog }
        }
        return result
    }()
    /// The translation of `source` in `language`, else in the Korean catalog, else `source` itself.
    public static func text(_ source: String, language: String? = nil) -> String {
        let language = language ?? languageCode
        return catalogs[language]?[source] ?? catalogs["ko"]?[source] ?? source
    }
    public static func format(_ source: String, _ arguments: Any...) -> String {
        format(source, arguments: arguments)
    }
    /// Formats the translated `source` with `arguments`, each passed as its string description.
    public static func format(_ source: String, arguments: [Any], language: String? = nil) -> String {
        String(format: text(source, language: language), locale: Locale.current,
               arguments: arguments.map { String(describing: $0) as CVarArg })
    }
    /// The Stop button title to show. A stored Korean default or an empty value follows the app
    /// language; any other text is the user's own and stays as written.
    public static func buttonTitle(_ value: String, language: String? = nil) -> String {
        value.isEmpty || value == "공유 중지" ? text("공유 중지", language: language) : value
    }
}
