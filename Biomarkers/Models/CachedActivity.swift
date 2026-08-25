import Foundation
import SwiftData

/// One Garmin activity, cached forever. Raw JSON is kept alongside the parsed
/// fields so a Garmin-side format change never destroys history — we can
/// re-parse the raw payloads after fixing the parser.
@Model
final class CachedActivity {
    @Attribute(.unique) var activityId: Int
    var name: String
    var typeKey: String
    var startDate: Date
    var durationSec: Double
    var calories: Double
    var trainingLoad: Double
    /// Seconds per HR zone; index 0 = Zone 1. Empty if zones were unavailable.
    var zoneSeconds: [Double]
    var rawSummaryJSON: String
    var rawZonesJSON: String
    var fetchedAt: Date

    init(activityId: Int, name: String, typeKey: String, startDate: Date,
         durationSec: Double, calories: Double, trainingLoad: Double,
         zoneSeconds: [Double],
         rawSummaryJSON: String, rawZonesJSON: String) {
        self.activityId = activityId
        self.name = name
        self.typeKey = typeKey
        self.startDate = startDate
        self.durationSec = durationSec
        self.calories = calories
        self.trainingLoad = trainingLoad
        self.zoneSeconds = zoneSeconds
        self.rawSummaryJSON = rawSummaryJSON
        self.rawZonesJSON = rawZonesJSON
        self.fetchedAt = Date()
    }

    /// Zone seconds folded into 5 buckets (zones 6+ merge into Z5).
    var fiveZoneSeconds: [Double] {
        var out = [Double](repeating: 0, count: 5)
        for (i, secs) in zoneSeconds.enumerated() {
            out[min(i, 4)] += secs
        }
        return out
    }
}
