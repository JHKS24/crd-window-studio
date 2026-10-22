import Foundation

/// System pane names that differ by macOS version. On macOS 27 the Privacy & Security pane that
/// grants the helper's permission is Device Control and Data Access (기기 제어 및 데이터 접근);
/// on earlier versions it is Accessibility (손쉬운 사용). The top-level Accessibility pane still exists
/// but holds VoiceOver and similar features, so the text follows the running system.
enum SystemNames {
    /// True on macOS 27 and later.
    static var usesDeviceControlName: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }
    /// The text for this system: `legacy` before macOS 27, `modern` from macOS 27.
    static func pick(_ legacy: @autoclosure () -> String, _ modern: @autoclosure () -> String,
                     deviceControl: Bool = usesDeviceControlName) -> String {
        deviceControl ? modern() : legacy()
    }
}
