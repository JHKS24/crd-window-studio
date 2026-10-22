import Foundation

/// The changes one numeric field edit should save. Leaving or submitting a
/// field without changing its number saves nothing and keeps the shape preset;
/// a real change to width, height or corner radius clears the preset.
public enum NumericEdit {
    public static let presetKeys: Set<String> = ["width", "height", "radius"]
    /// Returns nil when the number is unchanged.
    public static func changes(key: String, number: Double, current: [String: ConfigValue]) -> [String: ConfigValue]? {
        guard current[key]?.number != number else { return nil }
        var changes: [String: ConfigValue] = [key: .number(number)]
        if presetKeys.contains(key) { changes["shape"] = .string("custom") }
        return changes
    }
}
