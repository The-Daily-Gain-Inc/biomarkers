import Foundation
import AppIntents
import WidgetKit

/// Pulls today's headline numbers straight from the providers, inside the
/// widget extension — no app launch needed. Oura: last night's sleep /
/// readiness / HRV / resting HR. Garmin: today's steps. Weight is left as
/// the app last published it (the scale syncs through the app).
@MainActor
enum TodayRefresher {
    static let lastAttemptKey = "widget_last_refresh_attempt"

    static var lastAttempt: Date {
        Date(timeIntervalSince1970: WidgetBridge.defaults?.double(forKey: lastAttemptKey) ?? 0)
    }

    /// Fetches and republishes the snapshot. Returns true when anything new landed.
    @discardableResult
    static func refresh() async -> Bool {
        WidgetBridge.defaults?.set(Date().timeIntervalSince1970, forKey: lastAttemptKey)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.date(byAdding: .day, value: -6, to: today)!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        var byDay: [String: [Date: Double]] = [:]
        // Seed with what the app published so a partial pull never blanks a tile.
        let previous = WidgetBridge.load()
        func put(_ key: String, _ day: Date, _ v: Double) { byDay[key, default: [:]][cal.startOfDay(for: day)] = v }

        async let ouraDone: Bool = pullOura(start: weekStart, end: tomorrow, put: put)
        async let garminDone: Bool = pullGarmin(days: (0..<7).map { cal.date(byAdding: .day, value: $0, to: weekStart)! }, put: put)
        let (o, g) = await (ouraDone, garminDone)
        guard o || g else { return false }

        var metrics: [WidgetMetric] = []
        for id in WidgetBridge.headlineIds {
            if let days = byDay[id], let m = WidgetBridge.metric(id: id, byDay: days) {
                metrics.append(m)
            } else if let old = previous?.metrics.first(where: { $0.id == id }) {
                metrics.append(old)
            }
        }
        guard !metrics.isEmpty else { return false }
        WidgetBridge.save(WidgetSnapshot(metrics: metrics, updatedAt: Date()))
        return true
    }

    private static func pullOura(start: Date, end: Date, put: (String, Date, Double) -> Void) async -> Bool {
        let session = OuraSession()
        guard session.isConnected else { return false }
        let client = OuraClient(session: session)
        var any = false
        func day(_ r: [String: Any]) -> Date? { (r["day"] as? String).flatMap { GarminClient.dayFormatter.date(from: $0) } }
        if let rows = try? await client.dailyCollection("daily_sleep", start: start, end: end) {
            for r in rows { if let d = day(r), let s = (r["score"] as? NSNumber)?.doubleValue { put("sleep_score", d, s); any = true } }
        }
        if let rows = try? await client.dailyCollection("daily_readiness", start: start, end: end) {
            for r in rows { if let d = day(r), let s = (r["score"] as? NSNumber)?.doubleValue { put("readiness", d, s); any = true } }
        }
        if let rows = try? await client.dailyCollection("sleep", start: start, end: end) {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoPlain = ISO8601DateFormatter(); isoPlain.formatOptions = [.withInternetDateTime]
            for r in rows where (r["type"] as? String) == "long_sleep" {
                // Date by the morning you woke, like the app does.
                let wake = (r["bedtime_end"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
                guard let d = wake ?? day(r) else { continue }
                if let v = (r["average_hrv"] as? NSNumber)?.doubleValue { put("o_hrv", d, v); any = true }
                if let v = (r["lowest_heart_rate"] as? NSNumber)?.doubleValue, v > 0 { put("rhr", d, v); any = true }
            }
        }
        return any
    }

    private static func pullGarmin(days: [Date], put: (String, Date, Double) -> Void) async -> Bool {
        let session = SessionStore()
        guard session.isLoggedIn else { return false }
        let client = GarminClient(session: session)
        var any = false
        // Today is what matters; earlier days only feed the sparkline, so a
        // failure there is not a failed refresh.
        for day in days.reversed() {
            guard let summary = try? await client.dailySummary(date: day),
                  let v = (summary["totalSteps"] as? NSNumber)?.doubleValue else {
                if day == days.last { return false }
                continue
            }
            put("steps", day, v); any = true
        }
        return any
    }
}

/// The widget's refresh button. Runs in the extension process.
struct RefreshTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Biomarkers"
    static var description = IntentDescription("Pulls today's numbers from Oura and Garmin.")

    func perform() async throws -> some IntentResult {
        await TodayRefresher.refresh()
        return .result()
    }
}
