import Foundation
import SwiftData

/// Shared, off-main HR-zone bucketing cache. Both the Dashboard (daily) and
/// Trends (history) zone sections read from this one instance, so the heavy
/// per-activity re-bucketing runs once per (activities, Max HR) change instead
/// of once per host tab.
@MainActor
final class ZoneAggregator: ObservableObject {
    @Published private(set) var cache: [Int: [Double]] = [:]
    /// Bumps every time the cache is rebuilt — a cheap trigger for views that
    /// derive their series from it.
    @Published private(set) var version = 0
    private var key = ""

    /// True once bucketing has produced results.
    var isReady: Bool { !cache.isEmpty }

    /// Bucketed zone seconds for one activity (falls back to Garmin's split
    /// until the cache is built).
    func zoneSecs(_ a: CachedActivity) -> [Double] {
        cache[a.activityId] ?? a.fiveZoneSeconds
    }

    /// Rebuild off the main thread when inputs change; a no-op if the signature
    /// is unchanged, so two hosts triggering it don't double-compute.
    func rebuild(signature: String, activities: [CachedActivity], floors: [Int]) async {
        guard key != signature else { return }
        let snaps: [(Int, [Int], [Double], [Double])] =
            activities.map { ($0.activityId, $0.hrBpm, $0.hrElapsed, $0.fiveZoneSeconds) }
        let result = await Task.detached(priority: .userInitiated) { () -> [Int: [Double]] in
            var dict = [Int: [Double]](minimumCapacity: snaps.count)
            for s in snaps {
                dict[s.0] = Self.bucket(bpm: s.1, elapsed: s.2, floors: floors, fallback: s.3)
            }
            return dict
        }.value
        cache = result
        key = signature
        version += 1
    }

    /// Time-in-zone from a raw HR series against `floors`; mirrors
    /// CachedActivity.zoneSeconds(floors:) but runs on a Sendable snapshot.
    nonisolated static func bucket(bpm: [Int], elapsed: [Double],
                                   floors: [Int], fallback: [Double]) -> [Double] {
        guard !bpm.isEmpty, floors.count == 5 else { return fallback }
        var out = [Double](repeating: 0, count: 5)
        for i in bpm.indices {
            let hr = bpm[i]
            guard hr >= floors[0] else { continue }
            var zone = 0
            for z in 0..<5 where hr >= floors[z] { zone = z }
            let dwell = i + 1 < elapsed.count ? min(max(elapsed[i + 1] - elapsed[i], 0), 120) : 1
            out[zone] += dwell
        }
        return out
    }

    /// Signature of the inputs the cache depends on: Max HR, activity count,
    /// and how many activities have their raw HR series (a backfill flips
    /// `hrChecked`, so it re-triggers the rebuild). Only scalar properties
    /// are read: summing `hrBpm.count` decoded every activity's HR array on
    /// the main thread on every render.
    static func signature(activities: [CachedActivity], maxHR: Int) -> String {
        var withHR = 0
        for a in activities where a.hrChecked { withHR += 1 }
        return "\(maxHR)-\(activities.count)-\(withHR)"
    }
}
