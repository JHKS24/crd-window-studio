import AppKit
import SwiftUI

extension Color {
    /// The color for a configuration value: a palette name, a #RRGGBB hex value, or `fallback` for "system".
    static func configuration(_ value: String, fallback: Color) -> Color {
        switch value {
        case "system": return fallback
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "graphite": return Color(nsColor: .systemGray)
        default:
            guard value.hasPrefix("#"), let rgb = UInt32(value.dropFirst(), radix: 16) else { return fallback }
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }
    }
    /// The color as #RRGGBB in sRGB.
    var hexRGB: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}

/// Colors and color scheme derived from the settings.
extension SettingsStore {
    var colorScheme: ColorScheme? {
        switch string("appearance") { case "light": return .light; case "dark": return .dark; default: return nil }
    }
    var accentColor: Color { .configuration(string("accent"), fallback: .accentColor) }
    var dotColor: Color {
        let value = string("dotColor")
        return .configuration(value == "accent" ? string("accent") : value, fallback: Color(nsColor: .controlAccentColor))
    }
}
