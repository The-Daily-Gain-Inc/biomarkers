import Foundation
import SwiftData
import SwiftUI

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

    /// Oura resilience levels, low→high, mapped to a 1…5 score for charting.
    static let resilienceLevels = ["Limited", "Adequate", "Solid", "Strong", "Exceptional"]
    static func resilienceLabel(_ v: Double) -> String {
        resilienceLevels[min(max(Int(v.rounded()) - 1, 0), 4)]
    }
    static func resilienceScore(_ level: String) -> Double? {
        resilienceLevels.firstIndex { $0.caseInsensitiveCompare(level) == .orderedSame }.map { Double($0 + 1) }
    }

    /// Whether a higher value is the healthier direction (drives delta colors).
    static let higherIsBetter: [String: Bool] = [
        "workout_cal": true, "gym": true, "vo2": true, "fit_age": false,
        "load": true, "rhr": false, "steps": true,
        "readiness": true, "resilience": true, "o_hrv": true, "o_stress": false, "o_activity": true, "spo2": true,
        "years": true, "sleep_score": true, "sleep_hours": true,
        "rp_bodyfat": false, "rp_weight": false,
        "glucose": false, "bp_sys": false, "bp_dia": false, "ear": false,
        "porn": false, "reading": true, "meditation": true,
    ]

    /// Accent color per metric (detail views, Today cells).
    static func tint(for id: String) -> Color { Color(hex: tintHex(for: id)) }

    static func tintHex(for id: String) -> UInt32 {
        let map: [String: UInt32] = [
            "readiness": 0x2FA36B, "resilience": 0x2FA36B, "sleep_score": 0x5B6CF0, "sleep_hours": 0x5B6CF0,
            "o_stress": 0xE0791F, "o_activity": 0x00A6A0, "steps": 0x2E8BE6,
            "o_hrv": 0x8A6BD6, "rhr": 0xD1477A, "vo2": 0x2FA36B, "spo2": 0x2E8BE6,
            "rp_weight": 0x00A6A0, "rp_bodyfat": 0xE0791F, "fit_age": 0x8A6BD6,
            "years": 0x2FA36B, "load": 0xD1477A, "workout_cal": 0xE0791F, "gym": 0x2E8BE6,
            "glucose": 0xE0791F, "bp_sys": 0xD1477A, "bp_dia": 0xD1477A, "ear": 0x00A6A0,
            "reading": 0x5B6CF0, "meditation": 0x2FA36B, "porn": 0xD1477A,
        ]
        return map[id] ?? 0x2E8BE6
    }

    /// Manually-entered metrics: (key, label, unit). Logged via the Log sheet,
    /// cached like everything else so they appear on the dashboard and Trends.
    /// Built-in manual metrics plus any user-defined custom biomarkers.
    static var manualMetrics: [(key: String, label: String, unit: String?)] {
        builtinManualMetrics + CustomMetricStore.all().map {
            ($0.id, $0.name, $0.unit.isEmpty ? nil : $0.unit)
        }
    }

    static let builtinManualMetrics: [(key: String, label: String, unit: String?)] = [
        ("glucose", "Glucose", "mmol/L"),
        ("bp_sys", "BP Systolic", "mmHg"),
        ("bp_dia", "BP Diastolic", "mmHg"),
        ("ear", "Ear Age", "yrs"),
        ("porn", "Porn", "/wk"),
        ("reading", "Reading", nil),
        ("meditation", "Meditation", nil),
    ]

    static var placeholders: [Metric] {
        return [
        .init(id: "workout_cal", titleKey: "Calories Burned", provider: .garmin, unit: "kcal"),
        .init(id: "gym", titleKey: "Gym & Fitness", provider: .garmin, unit: "workouts"),
        .init(id: "vo2", titleKey: "VO2 Max", provider: .oura),
        .init(id: "fit_age", titleKey: "Fitness Age", provider: .garmin, unit: "yrs"),
        .init(id: "load", titleKey: "Training Load", provider: .garmin),
        .init(id: "rhr", titleKey: "Resting HR", provider: .oura, unit: "bpm"),
        .init(id: "steps", titleKey: "Steps Avg", provider: .garmin),
        .init(id: "readiness", titleKey: "Readiness", provider: .oura),
        .init(id: "resilience", titleKey: "Resilience", provider: .oura),
        .init(id: "o_hrv", titleKey: "HRV", provider: .oura, unit: "ms"),
        .init(id: "o_stress", titleKey: "Stress", provider: .oura, unit: "h high"),
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
    }

    /// Spec for a metric id — built-in, or synthesized for a custom biomarker.
    static func spec(for id: String) -> Spec? {
        if let s = specs[id] { return s }
        if let c = CustomMetricStore.all().first(where: { $0.id == id }) {
            let dec = c.decimals
            return Spec(agg: .latest, format: { dec > 0 ? String(format: "%.\(dec)f", $0) : String(Int($0.rounded())) })
        }
        return nil
    }

    /// Direction (higher-is-better) for a metric id, including custom ones.
    static func direction(for id: String) -> Bool {
        if let b = higherIsBetter[id] { return b }
        return CustomMetricStore.all().first { $0.id == id }?.higherIsBetter ?? true
    }

    /// How each cached-metric tile aggregates its 7-day series into a headline.
    enum Agg { case avg, latest }
    struct Spec { let agg: Agg; let format: (Double) -> String }
    static let specs: [String: Spec] = [
        "steps":       .init(agg: .avg,    format: { String(Int($0.rounded())) }),
        "fit_age":     .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "rhr":         .init(agg: .avg,    format: { String(Int($0.rounded())) }),
        "vo2":         .init(agg: .latest, format: { String(format: "%.1f", $0) }),
        "readiness":   .init(agg: .avg,    format: { String(Int($0.rounded())) }),
        "resilience":  .init(agg: .latest, format: { DashboardModel.resilienceLabel($0) }),
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
        "glucose":     .init(agg: .latest, format: { String(format: "%.1f", $0) }),
        "bp_sys":      .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "bp_dia":      .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "ear":         .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "porn":        .init(agg: .latest, format: { String(format: "%.1f", $0) }),
        "reading":     .init(agg: .latest, format: { String(Int($0.rounded())) }),
        "meditation":  .init(agg: .latest, format: { String(Int($0.rounded())) }),
    ]

    /// In-memory index of DailyMetric by id, built once per load so upserts and
    /// cache checks are O(1) dictionary hits instead of a SwiftData fetch each —
    /// the fetch-per-write was what made syncs/load-more block the UI.
    private var metricIndex: [String: DailyMetric] = [:]

    private func loadIndex(_ context: ModelContext) {
        metricIndex.removeAll(keepingCapacity: true)
        if let all = try? context.fetch(FetchDescriptor<DailyMetric>()) {
            for m in all { metricIndex[m.id] = m }
        }
    }

    /// Values staged during a render pass, then flushed to `metrics` in one
    /// assignment so the grid (and its charts) invalidate once, not per metric.
    private var working: [Metric] = []
    private var staging = false

    private func set(_ id: String, value: String?, series: [Double] = []) {
        if staging {
            guard let idx = working.firstIndex(where: { $0.id == id }) else { return }
            working[idx].value = value
            working[idx].series = series
        } else {
            guard let idx = metrics.firstIndex(where: { $0.id == id }) else { return }
            metrics[idx].value = value
            metrics[idx].series = series
        }
    }

    /// Freshness gate — most data is cached and rarely changes, so tab
    /// switches render from cache and only hit the network when stale or forced.
    static func isStale(_ interval: TimeInterval = 900) -> Bool {
        Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastNetworkSync") > interval
    }
    static func markSynced() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastNetworkSync")
    }

    func load(context: ModelContext, garmin: SessionStore, oura: OuraSession, renpho: RenphoSession, cacheOnly: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .day, value: -6, to: todayStart)!
        let days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: windowStart)! }

        loadIndex(context)
        // 1. Instant render from cache.
        renderFromCache(context: context, days: days)
        if cacheOnly { return }

        // 2. Refresh from network into the cache, then re-render.
        async let g: Void = loadGarmin(context: context, garmin: garmin, days: days)
        async let o: Void = loadOura(context: context, oura: oura, windowStart: windowStart, todayStart: todayStart)
        async let r: Void = loadRenpho(context: context, renpho: renpho)
        _ = await (g, o, r)
        try? context.save()
        Self.markSynced()

        renderFromCache(context: context, days: days)
    }

    /// Fetches and caches daily metrics over a wider window (for the Trends
    /// matrix). Reuses the same per-day cache, so it only downloads days not
    /// already stored.
    func loadHistory(context: ModelContext, garmin: SessionStore, oura: OuraSession, renpho: RenphoSession, weeks: Int, cacheOnly: Bool = false) async {
        // Trends renders from the SwiftData cache already; only fetch when
        // stale or forced (e.g. Load-more / pull-to-refresh).
        if cacheOnly { return }
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let totalDays = weeks * 7
        let windowStart = cal.date(byAdding: .day, value: -(totalDays - 1), to: today)!
        let days = (0..<totalDays).map { cal.date(byAdding: .day, value: $0, to: windowStart)! }

        loadIndex(context)
        async let g: Void = loadGarmin(context: context, garmin: garmin, days: days)
        async let o: Void = loadOura(context: context, oura: oura, windowStart: windowStart, todayStart: today)
        async let r: Void = loadRenpho(context: context, renpho: renpho)
        _ = await (g, o, r)
        try? context.save()
        Self.markSynced()
    }

    /// Force a fresh Oura pull over a wider window, ignoring the freshness
    /// gate — for the "Sync Oura Now" button when the ring lagged.
    func syncOuraNow(context: ModelContext, oura: OuraSession, days: Int = 14) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .day, value: -(days - 1), to: todayStart)!
        loadIndex(context)
        await loadOura(context: context, oura: oura, windowStart: windowStart, todayStart: todayStart)
        try? context.save()
        Self.markSynced()
    }

    // MARK: - Cache read

    private func renderFromCache(context: ModelContext, days: [Date]) {
        // Rebuild from the current placeholder set so newly-added custom
        // biomarkers appear, then fill values (single publish at the end).
        working = Self.placeholders
        staging = true
        defer {
            staging = false
            metrics = working   // single publish → one grid invalidation
            WidgetPublisher.publish(rows: Array(metricIndex.values))
        }
        loadFromActivityCache(context: context, windowStart: days.first!)

        let all = Array(metricIndex.values)
        let dayStarts = days.map { Calendar.current.startOfDay(for: $0) }
        for metric in Self.placeholders {
            let key = metric.id
            guard !Self.activityMetricIds.contains(key), let spec = Self.spec(for: key) else { continue }
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
        if let existing = metricIndex[id] {
            existing.value = value
            existing.fetchedAt = Date()
        } else {
            let m = DailyMetric(day: day, metricKey: key, value: value)
            context.insert(m)
            metricIndex[id] = m
        }
    }

    private func isCached(_ context: ModelContext, day: Date, key: String) -> Bool {
        metricIndex[DailyMetric.makeId(day: day, key: key)] != nil
    }

    // MARK: - Garmin

    private func loadGarmin(context: ModelContext, garmin: SessionStore, days: [Date]) async {
        guard garmin.isLoggedIn else { return }
        let client = GarminClient(session: garmin)
        let today = Calendar.current.startOfDay(for: Date())

        let fitAgeKeys = ["fitnessAge", "currentFitnessAge", "achievableFitnessAge"]
        for day in days {
            // Skip network for fully-cached past days; today always refreshes.
            let past = day < today
            let needSteps = !(past && isCached(context, day: day, key: "steps"))
            let needFitAge = !(past && isCached(context, day: day, key: "fit_age"))
            if !needSteps && !needFitAge { continue }
            if needSteps, let summary = try? await client.dailySummary(date: day),
               let v = (summary["totalSteps"] as? NSNumber)?.doubleValue {
                upsert(context, day: day, key: "steps", value: v)
            }
            // Fitness age per day, so it has a Trends history too.
            if needFitAge, let fa = try? await client.fitnessAge(date: day),
               let v = fitAgeKeys.compactMap({ (fa[$0] as? NSNumber)?.doubleValue }).first {
                upsert(context, day: day, key: "fit_age", value: v)
            }
            // Stress comes from Oura only (Garmin's 0–100 level is not used).
        }
        if let sync = try? await client.lastDeviceSync() { Self.setSynced("garmin", sync) }
        if let battery = try? await client.deviceBattery() {
            UserDefaults.standard.set(battery, forKey: "battery.garmin")
        }
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

    /// Local calendar day of `bedtime_end` (when the sleep session ended) —
    /// the morning date the night's metrics belong to.
    private func wakeDay(from row: [String: Any]) -> Date? {
        guard let s = row["bedtime_end"] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = f.date(from: s)
        if date == nil {
            f.formatOptions = [.withInternetDateTime]
            date = f.date(from: s)
        }
        return date.map { Calendar.current.startOfDay(for: $0) }
    }

    private func loadOura(context: ModelContext, oura: OuraSession, windowStart: Date, todayStart: Date) async {
        guard oura.isConnected else { return }
        let client = OuraClient(session: oura)
        let end = Date()
        // Query through *tomorrow* so an inclusive/exclusive end_date boundary
        // can never clip today's freshly-synced records.
        let qEnd = Calendar.current.date(byAdding: .day, value: 1, to: end)!
        // Track the newest real datapoint across *every* collection, so the
        // "last Oura data" reflects last night's sleep even when all-day HR
        // hasn't uploaded yet.
        var newest: Date?
        func note(_ d: Date?) { if let d, d > (newest ?? .distantPast) { newest = d } }
        var sleepCount = 0, sleepLatest: Date?
        var hrCount = 0, hrLatest: Date?

        if let rows = try? await client.dailyCollection("daily_sleep", start: windowStart, end: qEnd) {
            for r in rows where day(from: r) != nil {
                if let s = (r["score"] as? NSNumber)?.doubleValue { upsert(context, day: day(from: r)!, key: "sleep_score", value: s) }
            }
        }
        if let rows = try? await client.dailyCollection("daily_readiness", start: windowStart, end: qEnd) {
            for r in rows { if let d = day(from: r), let s = (r["score"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "readiness", value: s) } }
        }
        if let rows = try? await client.dailyCollection("daily_resilience", start: windowStart, end: qEnd) {
            for r in rows {
                if let d = day(from: r), let lvl = r["level"] as? String, let s = Self.resilienceScore(lvl) {
                    upsert(context, day: d, key: "resilience", value: s)
                }
            }
        }
        if let rows = try? await client.dailyCollection("sleep", start: windowStart, end: qEnd) {
            for r in rows where (r["type"] as? String) == "long_sleep" {
                sleepCount += 1
                let e = Self.preciseDate(from: r, key: "bedtime_end")
                if let e, e > (sleepLatest ?? .distantPast) { sleepLatest = e }
                note(e)
                // Date by the morning you woke (bedtime_end), so HRV/RHR/sleep
                // align with sleep_score/readiness instead of lagging a day.
                guard let d = wakeDay(from: r) ?? day(from: r) else { continue }
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
        if let rows = try? await client.dailyCollection("daily_activity", start: windowStart, end: qEnd) {
            for r in rows { if let d = day(from: r), let s = (r["score"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "o_activity", value: s) } }
        }
        if let rows = try? await client.dailyCollection("daily_stress", start: windowStart, end: qEnd) {
            for r in rows { if let d = day(from: r), let v = (r["stress_high"] as? NSNumber)?.doubleValue { upsert(context, day: d, key: "o_stress", value: v / 3600) } }
        }
        if let rows = try? await client.dailyCollection("daily_spo2", start: windowStart, end: qEnd) {
            for r in rows {
                if let d = day(from: r), let v = ((r["spo2_percentage"] as? [String: Any])?["average"] as? NSNumber)?.doubleValue {
                    upsert(context, day: d, key: "spo2", value: v)
                }
            }
        }
        if let rows = try? await client.dailyCollection("vO2_max", start: windowStart, end: qEnd) {
            for r in rows { if let d = day(from: r), let v = (r["vo2_max"] as? NSNumber)?.doubleValue, v > 0 { upsert(context, day: d, key: "vo2", value: v) } }
        }
        if let rows = try? await client.dailyCollection("daily_cardiovascular_age", start: windowStart, end: qEnd),
           let info = try? await client.personalInfo(), let age = (info["age"] as? NSNumber)?.doubleValue {
            // One point per day, so Years Younger has a Trends history — not just
            // today's value from the last row.
            for r in rows {
                if let d = day(from: r), let vascular = (r["vascular_age"] as? NSNumber)?.doubleValue {
                    upsert(context, day: d, key: "years", value: age - vascular)
                }
            }
        }
        // All-day HR is the most granular "ring last uploaded" signal. Probe a
        // few days back (cheap enough) and fold into `newest`.
        let hrStart = Calendar.current.date(byAdding: .day, value: -4, to: end)!
        if let samples = try? await client.heartRate(start: hrStart, end: qEnd) {
            hrCount = samples.count
            hrLatest = samples.compactMap { $0.date }.max()
            note(hrLatest)
        }
        // Per-source diagnostics: distinguishes "Oura cloud is stale" from "we
        // clipped/failed a fetch". Shows the latest sleep-end and HR times.
        func stamp(_ d: Date?) -> String { d.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "—" }
        DebugLog.shared.add("oura sleep=\(sleepCount) latest=\(stamp(sleepLatest)) | hr=\(hrCount) latest=\(stamp(hrLatest))")
        // Only ever advance the marker — never rewrite it older on a partial pull.
        if let newest {
            let prev = UserDefaults.standard.double(forKey: "lastUpdate.oura")
            if newest.timeIntervalSince1970 > prev { Self.setSynced("oura", newest) }
        }
    }

    /// Parse a full ISO-8601 datetime (with or without fractional seconds).
    static func preciseDate(from row: [String: Any], key: String) -> Date? {
        guard let s = row[key] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
