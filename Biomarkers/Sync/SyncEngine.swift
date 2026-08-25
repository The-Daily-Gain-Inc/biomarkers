import Foundation
import SwiftData

/// Pulls activities from Garmin page by page, fetches per-activity HR zones,
/// and upserts into the local cache. Incremental: stops at the first page
/// whose activities are all already cached, or at the backfill horizon.
@MainActor
final class SyncEngine: ObservableObject {
    @Published var isSyncing = false
    @Published var progressText: String?
    @Published var lastError: String?

    @discardableResult
    func sync(context: ModelContext, session: SessionStore, backfillMonths: Int) async -> Int {
        guard !isSyncing else { return 0 }
        isSyncing = true
        lastError = nil
        defer {
            isSyncing = false
            progressText = nil
        }

        let client = GarminClient(session: session)
        let horizon = Calendar.current.date(byAdding: .month, value: -backfillMonths, to: Date()) ?? .distantPast
        var knownIds = Set<Int>()
        if let existing = try? context.fetch(FetchDescriptor<CachedActivity>()) {
            knownIds = Set(existing.map(\.activityId))
        }

        var added = 0
        var start = 0
        let pageSize = 50
        do {
            pageLoop: while true {
                progressText = String(localized: "Fetching activities…")
                let (summaries, _) = try await client.activityList(start: start, limit: pageSize)
                if summaries.isEmpty { break }

                var pageHadNew = false
                for summary in summaries {
                    guard let date = summary.startDate else { continue }
                    if date < horizon { break pageLoop }
                    guard !knownIds.contains(summary.activityId) else { continue }
                    pageHadNew = true

                    progressText = String(localized: "Syncing \(summary.activityName ?? "activity")…")
                    var zoneSeconds: [Double] = []
                    var rawZones = ""
                    do {
                        let (zones, raw) = try await client.hrTimeInZones(activityId: summary.activityId)
                        rawZones = String(data: raw, encoding: .utf8) ?? ""
                        let byNumber = zones.compactMap { z -> (Int, Double)? in
                            guard let n = z.zoneNumber, n >= 1 else { return nil }
                            return (n, z.secsInZone ?? 0)
                        }
                        if let maxZone = byNumber.map(\.0).max() {
                            zoneSeconds = [Double](repeating: 0, count: maxZone)
                            for (n, secs) in byNumber { zoneSeconds[n - 1] += secs }
                        }
                    } catch GarminError.needsLogin {
                        throw GarminError.needsLogin
                    } catch {
                        // Zones missing for this activity (e.g. no HR data) — cache the
                        // summary anyway so we never refetch it in a tight loop.
                    }

                    let rawSummary: String
                    if let d = try? JSONEncoder().encode(RawSummaryEcho(summary)) {
                        rawSummary = String(data: d, encoding: .utf8) ?? ""
                    } else {
                        rawSummary = ""
                    }

                    let cached = CachedActivity(
                        activityId: summary.activityId,
                        name: summary.activityName ?? String(localized: "Activity"),
                        typeKey: summary.activityType?.typeKey ?? "unknown",
                        startDate: date,
                        durationSec: summary.duration ?? 0,
                        calories: summary.calories ?? 0,
                        trainingLoad: summary.activityTrainingLoad ?? 0,
                        zoneSeconds: zoneSeconds,
                        rawSummaryJSON: rawSummary,
                        rawZonesJSON: rawZones
                    )
                    context.insert(cached)
                    knownIds.insert(summary.activityId)
                    added += 1

                    try? await Task.sleep(nanoseconds: 300_000_000) // be gentle
                }
                try? context.save()

                if !pageHadNew && start > 0 { break } // fully caught up
                if summaries.count < pageSize { break }
                start += pageSize
            }
            try? context.save()
            UserDefaults.standard.set(Date(), forKey: "lastGarminSync")
        } catch GarminError.needsLogin {
            lastError = String(localized: "Garmin session expired — please sign in again.")
        } catch {
            lastError = error.localizedDescription
        }
        return added
    }
}

/// Re-encodes the decoded summary so the cache keeps a raw-ish copy even
/// though URLSession gave us the whole page in one blob.
private struct RawSummaryEcho: Encodable {
    let activityId: Int
    let activityName: String?
    let startTimeLocal: String?
    let duration: Double?
    let typeKey: String?
    init(_ s: GarminActivitySummary) {
        activityId = s.activityId
        activityName = s.activityName
        startTimeLocal = s.startTimeLocal
        duration = s.duration
        typeKey = s.activityType?.typeKey
    }
}
