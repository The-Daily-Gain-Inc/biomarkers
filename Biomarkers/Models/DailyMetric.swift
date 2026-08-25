import Foundation
import SwiftData

/// One cached metric value for one day (e.g. resting HR on 2026-08-24).
/// Persisted forever so history survives app restarts and provider outages,
/// and so already-fetched days are never re-downloaded.
@Model
final class DailyMetric {
    @Attribute(.unique) var id: String
    var day: Date
    var metricKey: String
    var value: Double
    var fetchedAt: Date

    init(day: Date, metricKey: String, value: Double) {
        let start = Calendar.current.startOfDay(for: day)
        self.day = start
        self.metricKey = metricKey
        self.value = value
        self.fetchedAt = Date()
        self.id = DailyMetric.makeId(day: start, key: metricKey)
    }

    static func makeId(day: Date, key: String) -> String {
        let start = Calendar.current.startOfDay(for: day)
        return "\(key)#\(Int(start.timeIntervalSince1970))"
    }
}
