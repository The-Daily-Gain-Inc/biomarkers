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
        // backfillMonths == 0 means all time.
        let horizon = backfillMonths == 0
            ? Date.distantPast
            : (Calendar.current.date(byAdding: .month, value: -backfillMonths, to: Date()) ?? .distantPast)
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
                    var zonesChecked = false
                    do {
                        let (zones, raw) = try await client.hrTimeInZones(activityId: summary.activityId)
                        rawZones = String(data: raw, encoding: .utf8) ?? ""
                        zoneSeconds = Self.parseZones(zones)
                        zonesChecked = true   // definitive answer (even if empty)
                    } catch GarminError.needsLogin {
                        throw GarminError.needsLogin
                    } catch {
                        // Fetch failed (rate limit / transient) — leave unchecked so
                        // the repair pass retries it, rather than losing zones forever.
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
                        rawZonesJSON: rawZones,
                        zonesChecked: zonesChecked
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

            // Repair pass: re-fetch zones for cached activities whose zone
            // fetch previously failed (empty + not definitively checked), so a
            // rate-limited backfill fills in over subsequent syncs.
            await repairMissingZones(context: context, client: client)

            UserDefaults.standard.set(Date(), forKey: "lastGarminSync")
        } catch GarminError.needsLogin {
            lastError = String(localized: "Garmin session expired — please sign in again.")
        } catch {
            lastError = error.localizedDescription
        }
        return added
    }

    /// Retries the HR-zone fetch for up to `limit` activities that are missing
    /// zones and haven't been definitively checked yet.
    private func repairMissingZones(context: ModelContext, client: GarminClient, limit: Int = 80) async {
        let all = (try? context.fetch(FetchDescriptor<CachedActivity>())) ?? []
        let needed = all.filter { $0.zoneSeconds.isEmpty && !$0.zonesChecked && $0.durationSec > 0 }
            .sorted { $0.startDate > $1.startDate }
            .prefix(limit)
        guard !needed.isEmpty else { return }
        var fixed = 0
        for act in needed {
            progressText = String(localized: "Recovering zones…")
            do {
                let (zones, raw) = try await client.hrTimeInZones(activityId: act.activityId)
                act.zoneSeconds = Self.parseZones(zones)
                act.rawZonesJSON = String(data: raw, encoding: .utf8) ?? act.rawZonesJSON
                act.zonesChecked = true
                fixed += 1
            } catch GarminError.needsLogin {
                break
            } catch {
                // still failing — leave unchecked for a future sync
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        try? context.save()
        if fixed > 0 { DebugLog.shared.add("zones repaired: \(fixed)") }
    }

    /// Sum seconds per zone (index 0 = Zone 1) from the raw zone list.
    static func parseZones(_ zones: [GarminZoneTime]) -> [Double] {
        let byNumber = zones.compactMap { z -> (Int, Double)? in
            guard let n = z.zoneNumber, n >= 1 else { return nil }
            return (n, z.secsInZone ?? 0)
        }
        guard let maxZone = byNumber.map(\.0).max() else { return [] }
        var out = [Double](repeating: 0, count: maxZone)
        for (n, secs) in byNumber { out[n - 1] += secs }
        return out
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
