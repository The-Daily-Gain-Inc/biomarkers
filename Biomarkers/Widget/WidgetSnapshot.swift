import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// One headline biomarker as the widget shows it. Compiled into the app and
/// the widget extension; the app publishes, the widget reads.
struct WidgetMetric: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    /// Already formatted by the app ("72", "7h 40m").
    var value: String
    var unit: String?
    /// Trailing days, oldest → newest, for the sparkline.
    var series: [Double]
    /// Accent color as 0xRRGGBB.
    var tint: UInt32
    var higherIsBetter: Bool
}

struct WidgetSnapshot: Codable, Equatable {
    var metrics: [WidgetMetric]
    var updatedAt: Date

    static let placeholder = WidgetSnapshot(metrics: [
        WidgetMetric(id: "readiness", title: "Readiness", value: "82", unit: nil, series: [70, 74, 78, 81, 77, 85, 82], tint: 0x2FA36B, higherIsBetter: true),
        WidgetMetric(id: "sleep_score", title: "Sleep", value: "76", unit: nil, series: [68, 80, 72, 79, 74, 77, 76], tint: 0x5B6CF0, higherIsBetter: true),
        WidgetMetric(id: "o_hrv", title: "HRV", value: "48", unit: "ms", series: [41, 44, 50, 47, 52, 45, 48], tint: 0x8A6BD6, higherIsBetter: true),
        WidgetMetric(id: "rhr", title: "Resting HR", value: "54", unit: "bpm", series: [56, 55, 54, 57, 53, 55, 54], tint: 0xD1477A, higherIsBetter: false),
    ], updatedAt: Date())
}

enum WidgetBridge {
    static let appGroup = "group.ca.thedailygain.biomarkers"
    static let snapshotKey = "widget_snapshot_v1"
    static let widgetKind = "BiomarkersTodayWidget"
    /// Which metric ids the widget shows, in order (first four fit).
    static let headlineIds = ["readiness", "sleep_score", "o_hrv", "rhr", "steps", "rp_weight"]

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroup)?.set(data, forKey: snapshotKey)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        #endif
    }
}
