import Foundation
import AppIntents
import WidgetKit

/// Pulls today's headline numbers straight from the providers, inside the
/// widget extension — no app launch needed. Oura: last night's sleep /
/// readiness / HRV / resting HR. Garmin: today's (and yesterday's) steps.
/// Renpho: latest weigh-ins.
@MainActor
enum TodayRefresher {
    static let lastAttemptKey = "widget_last_refresh_attempt"
    static let statusKey = "widget_refresh_status"

    /// Short outcome of the last refresh attempt, shown in the widget header
    /// when something went wrong ("" when all good).
    nonisolated static var status: String {
        get { WidgetBridge.defaults?.string(forKey: statusKey) ?? "" }
        set { WidgetBridge.defaults?.set(newValue, forKey: statusKey) }
    }

    nonisolated static var lastAttempt: Date {
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

        let ouraSession = OuraSession(), garminSession = SessionStore(), renphoSession = RenphoSession()
        guard ouraSession.isConnected || garminSession.isLoggedIn || renphoSession.isConnected else {
            status = String(localized: "Not signed in — open the app once")
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetBridge.widgetKind)
            return false
        }
        // Yesterday + today only for Garmin: the intent has a tight time
        // budget, and older days are already in the sparkline.
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        async let ouraDone: Bool = pullOura(ouraSession, start: weekStart, end: tomorrow, put: put)
        async let garminDone: Bool = pullGarmin(garminSession, days: [yesterday, today], put: put)
        async let renphoDone: Bool = pullRenpho(renphoSession, put: put)
        let (o, g, r) = await (ouraDone, garminDone, renphoDone)
        var failed: [String] = []
        if ouraSession.isConnected && !o { failed.append("Oura") }
        if garminSession.isLoggedIn && !g { failed.append("Garmin") }
        if renphoSession.isConnected && !r { failed.append("Renpho") }
        status = failed.isEmpty ? "" : String(localized: "Couldn't reach ") + failed.joined(separator: ", ")
        guard o || g || r else {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetBridge.widgetKind)
            return false
        }
        // Keep the previously published days for the sparklines, newest wins.
        for m in previous?.metrics ?? [] where byDay[m.id] != nil || m.id == "steps" {
            // Only steps has a day-indexed history we can't rebuild here; other
            // metrics are re-pulled for the whole week.
            guard m.id == "steps", byDay["steps"] != nil else { continue }
            let days = m.series.indices.map { i in cal.date(byAdding: .day, value: -(m.series.count - 1 - i), to: m.day ?? today)! }
            for (d, v) in zip(days, m.series) where byDay["steps"]?[d] == nil { put("steps", d, v) }
        }

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

    private static func pullOura(_ session: OuraSession, start: Date, end: Date, put: (String, Date, Double) -> Void) async -> Bool {
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
        if let rows = try? await client.dailyCollection("daily_stress", start: start, end: end) {
            for r in rows { if let d = day(r), let v = (r["stress_high"] as? NSNumber)?.doubleValue { put("o_stress", d, v / 3600); any = true } }
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

    private static func pullGarmin(_ session: SessionStore, days: [Date], put: (String, Date, Double) -> Void) async -> Bool {
        guard session.isLoggedIn else { return false }
        let client = GarminClient(session: session)
        var any = false
        for day in days.reversed() {
            guard let summary = try? await client.dailySummary(date: day),
                  let v = (summary["totalSteps"] as? NSNumber)?.doubleValue else {
                if day == days.last { return false }   // today failed → refresh failed
                continue
            }
            put("steps", day, v); any = true
        }
        return any
    }

    private static func pullRenpho(_ session: RenphoSession, put: (String, Date, Double) -> Void) async -> Bool {
        guard session.isConnected else { return false }
        guard let measurements = try? await RenphoClient(session: session).measurements(), !measurements.isEmpty else { return false }
        for m in measurements { if let w = m.values["rp_weight"] { put("rp_weight", m.date, w) } }
        return true
    }
}

/// The widget's refresh button. Runs in the extension process.
struct RefreshTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Biomarkers"
    static var description = IntentDescription("Pulls today's numbers from Oura, Garmin and Renpho.")

    func perform() async throws -> some IntentResult {
        await TodayRefresher.refresh()
        return .result()
    }
}
