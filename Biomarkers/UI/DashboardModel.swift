import Foundation
import SwiftData

struct Metric: Identifiable {
    enum Provider: String {
        case garmin = "Garmin"
        case oura = "Oura"
        case renpho = "Renpho"
        case manual = "Manual"
    }

    let id: String
    let titleKey: String
    let provider: Provider
    var value: String?
    var unit: String?
    var series: [Double] = []
}

/// Loads the dashboard biomarkers for the trailing 7 days. Per-day values
/// are cached in SwiftData (DailyMetric), so the grid renders instantly from
/// the DB, old days are never re-downloaded, and history survives restarts
/// and provider outages. The network pass only refreshes the cache.
@MainActor
final class DashboardModel: ObservableObject {
    @Published var metrics: [Metric] = DashboardModel.placeholders
    @Published var isLoading = false
    @Published var isLoadingHistory = false

    /// Activity-derived tiles summed per week (not stored in DailyMetric).
    static let activityMetricIds: Set<String> = ["workout_cal", "gym", "load"]

    /// Manually-entered metrics: (key, label, unit). Logged via the Log sheet,
    /// cached like everything else so they appear on the dashboard and Trends.
    static let manualMetrics: [(key: String, label: String, unit: String?)] = [
        ("glucose", "Glucose", "mg/dL"),
        ("bp_sys", "BP Systolic", "mmHg"),
        ("bp_dia", "BP Diastolic", "mmHg"),
        ("ear", "Ear Health", "/10"),
        ("porn", "Porn", "/wk"),
        ("reading", "Reading", nil),
        ("meditation", "Meditation", nil),
    ]

    static let placeholders: [Metric] = [
        .init(id: "workout_cal", titleKey: "Calories Burned", provider: .garmin, unit: "kcal"),
        .init(id: "gym", titleKey: "Gym & Fitness", provider: .garmin, unit: "workouts"),
        .init(id: "vo2", titleKey: "VO2 Max", provider: .oura),
        .init(id: "fit_age", titleKey: "Fitness Age", provider: .garmin, unit: "yrs"),
        .init(id: "load", titleKey: "Training Load", provider: .garmin),
        .init(id: "rhr", titleKey: "Resting HR", provider: .oura, unit: "bpm"),
        .init(id: "stress", titleKey: "Stress", provider: .garmin),
        .init(id: "steps", titleKey: "Steps Avg", provider: .garmin),
        .init(id: "readiness", titleKey: "Readiness", provider: .oura),
        .init(id: "o_hrv", titleKey: "HRV", provider: .oura, unit: "ms"),
        .init(id: "o_stress", titleKey: "Oura Stress", provider: .oura, unit: "h high"),
        .init(id: "o_activity", titleKey: "Oura Activity", provider: .oura),
        .init(id: "spo2", titleKey: "Blood Oxygen %", provider: .oura, unit: "%"),
        .init(id: "years", titleKey: "Years Younger", provider: .oura, unit: "yrs"),
        .init(id: "sleep_score", titleKey: "Sleep Score", provider: .oura),
        .init(id: "sleep_hours", titleKey: "Sleep Hours", provider: .oura, unit: "h"),
        .init(id: "rp_bodyfat", titleKey: "Body Fat", provider: .renpho, unit: "%"),
        .init(id: "rp_weight", titleKey: "Weight", provider: .renpho, unit: "kg"),
    ] + DashboardModel.manualMetrics.map {
        Metric(id: $0.key, titleKey: $0.label, provider: .manual, unit: $0.unit)
    }

    /// How each cached-metric tile aggregates its 7-day series into a headline.
    enum Agg { case avg, latest }
    struct Spec { let agg: Agg; let format: (Double) -> String }
    static let specs: [String: Spec] = [
        "steps":       .init(agg: .avg,    format: { String(Int($0.rounded())) }),
        "stress":      .init(agg: .avg,    format: { String(Int($0.rounded())) }),
        "fit_age":     .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "rhr":         .init(agg: .avg,    format: { String(Int($0.rounded())) }),
        "vo2":         .init(agg: .latest, format: { String(format: "%.1f", $0) }),
        "readiness":   .init(agg: .avg,    format: { String(Int($0.rounded())) }),
        "o_hrv":       .init(agg: .avg,    format: { String(Int($0.rounded())) }),
        "o_stress":    .init(agg: .avg,    format: { String(format: "%.1f", $0) }),
        "o_activity":  .init(agg: .avg,    format: { String(Int($0.rounded())) }),
        "spo2":        .init(agg: .avg,    format: { String(format: "%.1f", $0) }),
        "years":       .init(agg: .latest, format: { String(format: "%+.0f", $0) }),
        "sleep_score": .init(agg: .avg,    format: { String(Int($0.rounded())) }),
        "sleep_hours": .init(agg: .avg,    format: { String(format: "%.1f", $0) }),
        // Renpho body composition — latest measurement, not averaged.
        "rp_bodyfat":  .init(agg: .latest, format: { String(format: "%.1f", $0) }),
        "rp_weight":   .init(agg: .latest, format: { String(format: "%.1f", $0) }),
        // Manual metrics — latest reading is the headline.
        "glucose":     .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "bp_sys":      .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "bp_dia":      .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "ear":         .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "porn":        .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "reading":     .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "meditation":  .init(agg: .latest, format: { String(Int($0.rounded())) }),
    ]

    private func set(_ id: String, value: String?, series: [Double] = []) {
        guard let idx = metrics.firstIndex(where: { $0.id == id }) else { return }
        metrics[idx].value = value
        metrics[idx].series = series
    }

    func load(context: ModelContext, garmin: SessionStore, oura: OuraSession, renpho: RenphoSession) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .day, value: -6, to: todayStart)!
        let days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: windowStart)! }

        // 1. Instant render from cache.
        renderFromCache(context: context, days: days)

        // 2. Refresh from network into the cache, then re-render.
        async let g: Void = loadGarmin(context: context, garmin: garmin, days: days)
        async let o: Void = loadOura(context: context, oura: oura, windowStart: windowStart, todayStart: todayStart)
        async let r: Void = loadRenpho(context: context, renpho: renpho)
        _ = await (g, o, r)
        try? context.save()

        renderFromCache(context: context, days: days)
    }

    /// Fetches and caches daily metrics over a wider window (for the Trends
    /// matrix). Reuses the same per-day cache, so it only downloads days not
    /// already stored.
    func loadHistory(context: ModelContext, garmin: SessionStore, oura: OuraSession, renpho: RenphoSession, weeks: Int) async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let totalDays = weeks * 7
        let windowStart = cal.date(byAdding: .day, value: -(totalDays - 1), to: today)!
        let days = (0..<totalDays).map { cal.date(byAdding: .day, value: $0, to: windowStart)! }

        async let g: Void = loadGarmin(context: context, garmin: garmin, days: days)
        async let o: Void = loadOura(context: context, oura: oura, windowStart: windowStart, todayStart: today)
        async let r: Void = loadRenpho(context: context, renpho: renpho)
        _ = await (g, o, r)
        try? context.save()
    }

    // MARK: - Cache read

    private func renderFromCache(context: ModelContext, days: [Date]) {
        loadFromActivityCache(context: context, windowStart: days.first!)

        let all = (try? context.fetch(FetchDescriptor<DailyMetric>())) ?? []
        let dayStarts = days.map { Calendar.current.startOfDay(for: $0) }
        for (key, spec) in Self.specs {
            let rows = all.filter { $0.metricKey == key }
            // Body composition is measured irregularly — show the latest
            // reading and its recent trend, not just the trailing 7 days.
            if key.hasPrefix("rp_") {
                let sorted = rows.sorted { $0.day < $1.day }
                guard let latest = sorted.last else { set(key, value: nil, series: []); continue }
                set(key, value: spec.format(latest.value), series: sorted.suffix(7).map(\.value))
                continue
            }
            let byDay = Dictionary(
                rows.map { ($0.day, $0.value) },
                uniquingKeysWith: { a, _ in a }
            )
            let series = dayStarts.compactMap { byDay[$0] }
            guard !series.isEmpty else { set(key, value: nil, series: []); continue }
            let headline: Double
            switch spec.agg {
            case .avg: headline = series.reduce(0, +) / Double(series.count)
            case .latest: headline = series.last ?? 0
            }
            set(key, value: spec.format(headline), series: series)
        }
    }

    private func loadFromActivityCache(context: ModelContext, windowStart: Date) {
        let predicate = #Predicate<CachedActivity> { $0.startDate >= windowStart }
        let recent = (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? []
        let calories = recent.map(\.calories).reduce(0, +)
        set("workout_cal", value: calories > 0 ? String(Int(calories)) : nil)
        let gymKeys = ["strength_training", "fitness_equipment", "indoor_cardio", "hiit", "yoga", "pilates"]
        let gym = recent.filter { a in gymKeys.contains(where: { a.typeKey.contains($0) }) }.count
        set("gym", value: recent.isEmpty ? nil : String(gym))
        let load = recent.map(\.trainingLoad).reduce(0, +)
        set("load", value: load > 0 ? String(Int(load)) : nil)
    }

    // MARK: - Cache write

    private func upsert(_ context: ModelContext, day: Date, key: String, value: Double) {
        let id = DailyMetric.makeId(day: day, key: key)
        let predicate = #Predicate<DailyMetric> { $0.id == id }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            existing.value = value
            existing.fetchedAt = Date()
        } else {
            context.insert(DailyMetric(day: day, metricKey: key, value: value))
        }
    }

    private func isCached(_ context: ModelContext, day: Date, key: String) -> Bool {
        let id = DailyMetric.makeId(day: day, key: key)
        let predicate = #Predicate<DailyMetric> { $0.id == id }
        return ((try? context.fetchCount(FetchDescriptor(predicate: predicate))) ?? 0) > 0
    }

    // MARK: - Garmin

    private func loadGarmin(context: ModelContext, garmin: SessionStore, days: [Date]) async {
        guard garmin.isLoggedIn else { return }
        let client = GarminClient(session: garmin)
        let today = Calendar.current.startOfDay(for: Date())

        for day in days {
            // Skip network for fully-cached past days; today always refreshes.
            let past = day < today
            if past, isCached(context, day: day, key: "steps") { continue }
            guard let summary = try? await client.dailySummary(date: day) else { continue }
            if let v = (summary["totalSteps"] as? NSNumber)?.doubleValue {
                upsert(context, day: day, key: "steps", value: v)
            }
            if let v = (summary["averageStressLevel"] as? NSNumber)?.doubleValue, v >= 0 {
                upsert(context, day: day, key: "stress", value: v)
            }
        }

        if let fa = try? await client.fitnessAge(date: Date()) {
            let candidates = ["fitnessAge", "currentFitnessAge", "achievableFitnessAge"]
            if let v = candidates.compactMap({ (fa[$0] as? NSNumber)?.doubleValue }).first {
                upsert(context, day: today, key: "fit_age", value: v)
            }
        }
        if let sync = try? await client.lastDeviceSync() { Self.setSynced("garmin", sync) }
    }

    // MARK: - Renpho

    private func loadRenpho(context: ModelContext, renpho: RenphoSession) async {
        guard renpho.isConnected else { return }
        let client = RenphoClient(session: renpho)
        guard let measurements = try? await client.measurements() else { return }
        // Sorted ascending, so the latest measurement of any day is stored last.
        for m in measurements {
            for (key, value) in m.values {
                upsert(context, day: m.date, key: key, value: value)
            }
        }
        // Last weigh-in is the scale's real "sync" moment.
        if let last = measurements.last?.date { Self.setSynced("renpho", last) }
    }

    /// Records when the provider's *device* last synced its data (not when we
    /// pulled) — shown on Today so the time reflects real data freshness.
    static func setSynced(_ provider: String, _ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "lastUpdate.\(provider)")
    }

    // MARK: - Oura

    private func day(from row: [String: Any]) -> Date? {
        guard let s = row["day"] as? String else { return nil }
        return GarminClient.dayFormatter.date(from: s)
    }

    private func loadOura(context: ModelContext, oura: OuraSession, windowStart: Date, todayStart: Date) async {
        guard oura.isConnected else { return }
        let client = OuraClient(session: oura)
        let end = Date()

        if let rows = try? await client.dailyCollection("daily_sleep", start: windowStart, end: end) {
            for r in rows where day(from: r) != nil {
                if let s = (r["score"] as? NSNumber)?.doubleValue { upsert(context, day: day(from: r)!, key: "sleep_score", value: s) }
            }
        }
        if let rows = try? await client.dailyCollection("daily_readiness", start: windowStart, end: end) {
            for r in rows { if let d = day(from: r), let s = (r["score"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "readiness", value: s) } }
        }
        if let rows = try? await client.dailyCollection("sleep", start: windowStart, end: end) {
            for r in rows where (r["type"] as? String) == "long_sleep" {
                guard let d = day(from: r) else { continue }
                if let v = (r["average_hrv"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "o_hrv", value: v) }
                if let v = (r["total_sleep_duration"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "sleep_hours", value: v / 3600) }
                if let v = (r["lowest_heart_rate"] as? NSNumber)?.doubleValue, v > 0 { upsert(context, day: d, key: "rhr", value: v) }
                // Sleep-stage durations (seconds → minutes) for the stages view.
                if let v = (r["deep_sleep_duration"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "sleep_deep", value: v / 60) }
                if let v = (r["light_sleep_duration"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "sleep_light", value: v / 60) }
                if let v = (r["rem_sleep_duration"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "sleep_rem", value: v / 60) }
                if let v = (r["awake_time"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "sleep_awake", value: v / 60) }
            }
        }
        if let rows = try? await client.dailyCollection("daily_activity", start: windowStart, end: end) {
            for r in rows { if let d = day(from: r), let s = (r["score"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "o_activity", value: s) } }
        }
        if let rows = try? await client.dailyCollection("daily_stress", start: windowStart, end: end) {
            for r in rows { if let d = day(from: r), let v = (r["stress_high"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "o_stress", value: v / 3600) } }
        }
        if let rows = try? await client.dailyCollection("daily_spo2", start: windowStart, end: end) {
            for r in rows {
                if let d = day(from: r), let v = ((r["spo2_percentage"] as? [String: Any])?["average"] as? NSNumber)?.doubleValue {
                    upsert(context, day: d, key: "spo2", value: v)
                }
            }
        }
        if let rows = try? await client.dailyCollection("vO2_max", start: windowStart, end: end) {
            for r in rows { if let d = day(from: r), let v = (r["vo2_max"] as? NSNumber)?.doubleValue, v > 0 { upsert(context, day: d, key: "vo2", value: v) } }
        }
        if let rows = try? await client.dailyCollection("daily_cardiovascular_age", start: windowStart, end: end),
           let vascular = rows.compactMap({ ($0["vascular_age"] as? NSNumber)?.doubleValue }).last {
            if let info = try? await client.personalInfo(), let age = (info["age"] as? NSNumber)?.doubleValue {
                upsert(context, day: todayStart, key: "years", value: age - vascular)
            }
        }
        // Latest heart-rate sample time ≈ when the ring last synced.
        if let samples = try? await client.heartRate(start: Calendar.current.date(byAdding: .day, value: -2, to: end)!, end: end),
           let latest = samples.compactMap({ $0.date }).max() {
            Self.setSynced("oura", latest)
        }
    }
}
