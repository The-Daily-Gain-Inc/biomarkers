import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// One headline biomarker as the widget shows it. Compiled into the app and
/// the widget extension; the app publishes, the widget reads (and can
/// refresh itself from the providers).
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
    /// The calendar day `value` belongs to. Nil = today. When the ring hasn't
    /// synced yet, the widget falls back to the most recent day and says so.
    var day: Date?

    var isToday: Bool {
        guard let day else { return true }
        return Calendar.current.isDateInToday(day)
    }
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
    static let snapshotKey = "widget_snapshot_v2"
    static let widgetKind = "BiomarkersTodayWidget"
    /// Which metric ids the widget shows, in order (first four fit).
    static let headlineIds = ["readiness", "sleep_score", "o_hrv", "rhr", "o_stress", "steps", "rp_weight"]

    /// Display metadata the widget needs even when it builds a metric itself.
    struct Info { let title: String; let unit: String?; let tint: UInt32; let higherIsBetter: Bool; let format: (Double) -> String }
    static let info: [String: Info] = [
        "readiness":   Info(title: "Readiness",  unit: nil,   tint: 0x2FA36B, higherIsBetter: true)  { String(Int($0.rounded())) },
        "sleep_score": Info(title: "Sleep Score", unit: nil,  tint: 0x5B6CF0, higherIsBetter: true)  { String(Int($0.rounded())) },
        "o_hrv":       Info(title: "HRV",        unit: "ms",  tint: 0x8A6BD6, higherIsBetter: true)  { String(Int($0.rounded())) },
        "rhr":         Info(title: "Resting HR", unit: "bpm", tint: 0xD1477A, higherIsBetter: false) { String(Int($0.rounded())) },
        "o_stress":    Info(title: "Stress",     unit: "h high", tint: 0xE0791F, higherIsBetter: false) { String(format: "%.1f", $0) },
        "steps":       Info(title: "Steps",      unit: nil,   tint: 0x2E8BE6, higherIsBetter: true)  { String(Int($0.rounded())) },
        "rp_weight":   Info(title: "Weight",     unit: "kg",  tint: 0x00A6A0, higherIsBetter: false) { String(format: "%.1f", $0) },
    ]

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: snapshotKey)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        #endif
    }

    /// Builds the widget's metric for `id` from per-day values (day-start →
    /// value). Headline = today's value; if today hasn't arrived, the most
    /// recent day in `byDay`, flagged via `day`. Weight is always the latest
    /// reading (the scale is stepped on irregularly).
    static func metric(id: String, byDay: [Date: Double]) -> WidgetMetric? {
        guard let info = info[id], !byDay.isEmpty else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let sortedDays = byDay.keys.sorted()
        let headlineDay: Date
        if id.hasPrefix("rp_") || byDay[today] == nil {
            headlineDay = sortedDays.last!
        } else {
            headlineDay = today
        }
        // Sparkline: the last 7 calendar days that have a value (weight: last 7 readings).
        let weekStart = cal.date(byAdding: .day, value: -6, to: today)!
        let seriesDays = id.hasPrefix("rp_") ? Array(sortedDays.suffix(7)) : sortedDays.filter { $0 >= weekStart }
        return WidgetMetric(id: id, title: info.title, value: info.format(byDay[headlineDay]!), unit: info.unit,
                            series: seriesDays.compactMap { byDay[$0] }, tint: info.tint,
                            higherIsBetter: info.higherIsBetter,
                            day: cal.isDateInToday(headlineDay) ? nil : headlineDay)
    }
}
