import Foundation

/// One value in the configuration file: a string, a number or a Boolean.
/// The accessors return an empty value when the case does not match.
public enum ConfigValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        }
    }
    public var string: String { if case .string(let v) = self { return v }; return "" }
    public var number: Double { if case .number(let v) = self { return v }; return 0 }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
}

/// One option of a choice setting. `title` is a localization key.
public struct SettingChoice: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public var localizedTitle: String { L10n.text(title) }
}
/// A built-in window shape and the settings values it applies.
public struct ShapePreset: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let values: [String: ConfigValue]
    public var localizedTitle: String { L10n.text(title) }
}
/// The bundled settings schema: default values, numeric limits, choice lists and shape presets.
public struct SettingsSchema: Codable, Sendable {
    public let defaults: [String: ConfigValue]
    public let numericLimits: [String: [Double]]
    public let choices: [String: [SettingChoice]]
    public let shapes: [ShapePreset]

    /// Loads the schema from the app bundle, or from the package resources when running tests.
    public static func load() throws -> Self {
        let packaged = Bundle.main.url(forResource: "SettingsSchema", withExtension: "json")
        guard let url = packaged ?? Bundle.module.url(forResource: "SettingsSchema", withExtension: "json") else {
            throw ConfigurationError.invalid(L10n.text("기본 설정을 찾을 수 없습니다. 앱을 다시 설치하세요."))
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    /// Returns the defaults overlaid with `input` after migration, and throws if any value is invalid.
    public func validate(_ input: [String: ConfigValue]) throws -> [String: ConfigValue] {
        var output = defaults
        output.merge(Self.migrated(input)) { _, new in new }
        try validateChanges(output)
        return output
    }
    /// Loads a saved `hidden` mode as `custom` without an error, so the next save writes `custom`.
    /// The helper's validation applies the same rule.
    public static func migrated(_ input: [String: ConfigValue]) -> [String: ConfigValue] {
        guard input["mode"] == .string("hidden") else { return input }
        var output = input
        output["mode"] = .string("custom")
        return output
    }
    /// Validates only the given fields: known keys, matching types, the file version, numeric ranges,
    /// choices, shapes, color formats and text length. Used before publishing an immediate preview.
    public func validateChanges(_ input: [String: ConfigValue]) throws {
        for (key, value) in input {
            guard let base = defaults[key] else { throw ConfigurationError.invalid(L10n.format("알 수 없는 설정 항목(%@)이 있습니다. 설정 파일에서 지우거나 기본값으로 되돌리세요.", key)) }
            switch (base, value) {
            case (.string, .string), (.number, .number), (.bool, .bool): break
            default: throw ConfigurationError.invalid(L10n.format("%@ 값이 올바르지 않습니다. 설정 파일을 확인하거나 기본값으로 되돌리세요.", key))
            }
            if key == "schema", value != defaults["schema"] { throw ConfigurationError.invalid(L10n.text("지원하지 않는 설정 파일 버전입니다. 기본값으로 되돌리거나 앱을 업데이트하세요.")) }
            if let range = numericLimits[key] {
                let n = value.number
                guard n.isFinite, range[0]...range[1] ~= n else { throw ConfigurationError.invalid(L10n.format("%@ 값은 %@~%@ 사이로 지정하세요.", key, range[0], range[1])) }
            }
            if key != "accent", let options = choices[key], !options.contains(where: { $0.id == value.string }) {
                throw ConfigurationError.invalid(L10n.format("%@ 설정이 올바르지 않습니다. 사용할 수 있는 값으로 바꾸거나 기본값으로 되돌리세요.", key))
            }
            if key == "shape", !shapes.contains(where: { $0.id == value.string }) { throw ConfigurationError.invalid(L10n.text("창 모양 설정이 올바르지 않습니다. 다른 창 모양을 고르거나 기본값으로 되돌리세요.")) }
            if ["background", "foreground", "accent", "dotColor"].contains(key) {
                let s = value.string
                let paletteColor = choices["accent", default: []].contains(where: { $0.id == s })
                let semantic = s == "system" || ((key == "accent" || key == "dotColor") && paletteColor)
                    || (key == "dotColor" && s == "accent")
                guard semantic || s.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                    throw ConfigurationError.invalid(L10n.format("%@ 색상이 올바르지 않습니다. 시스템 색상 이름이나 #RRGGBB 형식으로 입력하세요.", key))
                }
            }
            if case .string(let s) = value, s.count > 2048 { throw ConfigurationError.invalid(L10n.text("안내 문구가 너무 깁니다. 2,048자 이하로 입력하세요.")) }
        }
    }
}
/// A configuration problem with a localized message for the user.
public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
