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
    /// True once the zone endpoint returned a definitive answer (zones present
    /// or a valid empty response). False means the fetch failed and should be
    /// retried — so a rate-limited backfill doesn't leave zones missing forever.
    var zonesChecked: Bool = false

    /// Raw HR series (bpm) and each sample's elapsed seconds, so time-in-zone
    /// can be recomputed for the user's custom zone boundaries.
    var hrBpm: [Int] = []
    var hrElapsed: [Double] = []
    var hrChecked: Bool = false

    init(activityId: Int, name: String, typeKey: String, startDate: Date,
         durationSec: Double, calories: Double, trainingLoad: Double,
         zoneSeconds: [Double],
         rawSummaryJSON: String, rawZonesJSON: String, zonesChecked: Bool = false) {
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
        self.zonesChecked = zonesChecked
    }

    /// Zone seconds folded into 5 buckets (zones 6+ merge into Z5).
    var fiveZoneSeconds: [Double] {
        var out = [Double](repeating: 0, count: 5)
        for (i, secs) in zoneSeconds.enumerated() {
            out[min(i, 4)] += secs
        }
        return out
    }

    /// Time-in-zone recomputed from the raw HR series against custom `floors`
    /// (5 ascending bpm lower-bounds for Z1…Z5). Falls back to Garmin's
    /// pre-bucketed split when no HR series is stored yet.
    func zoneSeconds(floors: [Int]) -> [Double] {
        guard !hrBpm.isEmpty, floors.count == 5 else { return fiveZoneSeconds }
        var out = [Double](repeating: 0, count: 5)
        for i in hrBpm.indices {
            let bpm = hrBpm[i]
            guard bpm >= floors[0] else { continue }   // below Z1
            var zone = 0
            for z in 0..<5 where bpm >= floors[z] { zone = z }
            let dwell: Double
            if i + 1 < hrElapsed.count { dwell = min(max(hrElapsed[i + 1] - hrElapsed[i], 0), 120) }
            else { dwell = 1 }
            out[zone] += dwell
        }
        return out
    }
}
