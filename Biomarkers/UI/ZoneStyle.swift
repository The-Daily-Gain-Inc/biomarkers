import SwiftUI

/// HR zone colors — an ordered intensity ramp (recovery → max), validated
/// for both modes with the dataviz palette checks (lightness band, chroma
/// floor, CVD + normal-vision adjacent separation, surface contrast).
/// Identity never rides on color alone: zones are axis-positioned and bars
/// carry direct time labels.
enum ZonePalette {
    private static let light: [Color] = [
        Color(hex: 0x9F7BE8), // Z1
        Color(hex: 0x1B4FC4), // Z2
        Color(hex: 0x178A50), // Z3
        Color(hex: 0xE08700), // Z4
        Color(hex: 0xC61A1A), // Z5
    ]
    private static let dark: [Color] = [
        Color(hex: 0x8F76DB),
        Color(hex: 0x2360C8),
        Color(hex: 0x1C8F52),
        Color(hex: 0xC28800),
        Color(hex: 0xCC3333),
    ]

    /// zone is 1-based (1...5).
    static func color(zone: Int, scheme: ColorScheme) -> Color {
        let idx = min(max(zone - 1, 0), 4)
        return (scheme == .dark ? dark : light)[idx]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

func formatDuration(_ seconds: Double) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
    f.unitsStyle = .abbreviated
    return f.string(from: max(seconds, 0)) ?? "0m"
}
