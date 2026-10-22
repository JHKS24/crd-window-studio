import CRDSettingsCore

/// The two ways to hide again the Stop Sharing button that a double-click shows on any shape, stored
/// in the single key `stopRevealSeconds`: 0 is "until I hide it", 1 to 30 is "automatically after N seconds".
enum ShrinkSetting {
    static let key = "stopRevealSeconds"
    static let manualValue: Double = 0
    static let defaultSeconds: Double = 5
    static let automaticRange: ClosedRange<Double> = 1...30
    static let memoryKey = "lastAutomaticShrinkSeconds"

    static func isAutomatic(_ value: ConfigValue?) -> Bool { automaticSeconds(value) != nil }
    /// The seconds of an automatic value; nil for the manual way or anything outside 1 to 30.
    static func automaticSeconds(_ value: ConfigValue?) -> Double? {
        guard case .number(let seconds)? = value, automaticRange.contains(seconds) else { return nil }
        return seconds
    }
    /// The value the automatic way shows and stores: the current one, else the remembered one, else 5.
    static func seconds(current: ConfigValue?, remembered: Double?) -> Double {
        if let seconds = automaticSeconds(current) { return seconds }
        if let remembered, automaticRange.contains(remembered) { return remembered }
        return defaultSeconds
    }
}
