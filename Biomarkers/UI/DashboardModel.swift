import Foundation
import SwiftData

struct Metric: Identifiable {
    enum Provider: String {
        case garmin = "Garmin"
        case oura = "Oura"
    }

    let id: String
    let titleKey: String
    let provider: Provider
    var value: String?
    var unit: String?
    var series: [Double] = []
}

/// Loads the 16 dashboard biomarkers for the trailing 7 days. Every metric
/// fails independently — a broken endpoint shows "—", never an empty screen.
@MainActor
final class DashboardModel: ObservableObject {
    @Published var metrics: [Metric] = DashboardModel.placeholders
    @Published var isLoading = false

    static let placeholders: [Metric] = [
        .init(id: "workout_cal", titleKey: "Calories Burned", provider: .garmin, unit: "kcal"),
        .init(id: "gym", titleKey: "Gym & Fitness", provider: .garmin, unit: "workouts"),
        .init(id: "vo2", titleKey: "VO2 Max", provider: .garmin),
        .init(id: "fit_age", titleKey: "Fitness Age", provider: .garmin, unit: "yrs"),
        .init(id: "load", titleKey: "Training Load", provider: .garmin),
        .init(id: "rhr", titleKey: "Resting HR", provider: .garmin, unit: "bpm"),
        .init(id: "stress", titleKey: "Stress", provider: .garmin),
        .init(id: "steps", titleKey: "Steps Avg", provider: .garmin),
        .init(id: "o_hrv", titleKey: "HRV", provider: .oura, unit: "ms"),
        .init(id: "o_stress", titleKey: "Oura Stress", provider: .oura, unit: "h high"),
        .init(id: "o_activity", titleKey: "Oura Activity", provider: .oura),
        .init(id: "spo2", titleKey: "Blood Oxygen %", provider: .oura, unit: "%"),
        .init(id: "years", titleKey: "Years Younger", provider: .oura, unit: "yrs"),
        .init(id: "sleep_score", titleKey: "Sleep Score", provider: .oura),
        .init(id: "sleep_hours", titleKey: "Sleep Hours", provider: .oura, unit: "h"),
    ]

    private func set(_ id: String, value: String?, series: [Double] = []) {
        guard let idx = metrics.firstIndex(where: { $0.id == id }) else { return }
        metrics[idx].value = value
        if !series.isEmpty { metrics[idx].series = series }
    }

    func load(context: ModelContext, garmin: SessionStore, oura: OuraSession) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .day, value: -6, to: todayStart)!
        let days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: windowStart)! }

        loadFromActivityCache(context: context, windowStart: windowStart)

        async let g: Void = loadGarmin(garmin: garmin, days: days, windowStart: windowStart)
        async let o: Void = loadOura(oura: oura, windowStart: windowStart, todayStart: todayStart)
        _ = await (g, o)
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

    private func loadGarmin(garmin: SessionStore, days: [Date], windowStart: Date) async {
        guard garmin.isLoggedIn else { return }
        let client = GarminClient(session: garmin)

        var steps: [Double] = [], rhr: [Double] = [], stress: [Double] = []
        for day in days {
            guard let summary = try? await client.dailySummary(date: day) else { continue }
            steps.append((summary["totalSteps"] as? NSNumber)?.doubleValue ?? 0)
            if let v = (summary["restingHeartRate"] as? NSNumber)?.doubleValue, v > 0 { rhr.append(v) }
            if let v = (summary["averageStressLevel"] as? NSNumber)?.doubleValue, v >= 0 { stress.append(v) }
        }
        set("steps", value: steps.isEmpty ? nil : String(Int(steps.reduce(0, +) / Double(steps.count))), series: steps)
        set("rhr", value: rhr.isEmpty ? nil : String(Int(rhr.reduce(0, +) / Double(rhr.count))), series: rhr)
        set("stress", value: stress.isEmpty ? nil : String(Int(stress.reduce(0, +) / Double(stress.count))), series: stress)

        // HRV comes from Oura only — Garmin HRV intentionally not fetched.
        if let rows = try? await client.vo2maxDaily(start: windowStart, end: Date()) {
            let vals = rows.compactMap { ((($0["generic"] as? [String: Any])?["vo2MaxPreciseValue"]) as? NSNumber)?.doubleValue }
            if let last = vals.last { set("vo2", value: String(format: "%.1f", last), series: vals) }
        }
        if let fa = try? await client.fitnessAge(date: Date()) {
            let candidates = ["fitnessAge", "currentFitnessAge", "achievableFitnessAge"]
            if let v = candidates.compactMap({ (fa[$0] as? NSNumber)?.doubleValue }).first {
                set("fit_age", value: String(format: "%.0f", v))
            }
        }
    }

    private func loadOura(oura: OuraSession, windowStart: Date, todayStart: Date) async {
        guard oura.isConnected else { return }
        let client = OuraClient(session: oura)
        let end = Date()

        if let rows = try? await client.dailyCollection("daily_sleep", start: windowStart, end: end) {
            let scores = rows.compactMap { ($0["score"] as? NSNumber)?.doubleValue }
            set("sleep_score", value: scores.isEmpty ? nil : String(Int(scores.reduce(0, +) / Double(scores.count))), series: scores)
        }
        if let rows = try? await client.dailyCollection("sleep", start: windowStart, end: end) {
            let nights = rows.filter { ($0["type"] as? String) == "long_sleep" }
            let hrv = nights.compactMap { ($0["average_hrv"] as? NSNumber)?.doubleValue }
            set("o_hrv", value: hrv.isEmpty ? nil : String(Int(hrv.reduce(0, +) / Double(hrv.count))), series: hrv)
            let hours = nights.compactMap { ($0["total_sleep_duration"] as? NSNumber)?.doubleValue }.map { $0 / 3600 }
            set("sleep_hours", value: hours.isEmpty ? nil : String(format: "%.1f", hours.reduce(0, +) / Double(hours.count)), series: hours)
        }
        if let rows = try? await client.dailyCollection("daily_activity", start: windowStart, end: end) {
            let scores = rows.compactMap { ($0["score"] as? NSNumber)?.doubleValue }
            set("o_activity", value: scores.isEmpty ? nil : String(Int(scores.reduce(0, +) / Double(scores.count))), series: scores)
        }
        if let rows = try? await client.dailyCollection("daily_stress", start: windowStart, end: end) {
            let high = rows.compactMap { ($0["stress_high"] as? NSNumber)?.doubleValue }.map { $0 / 3600 }
            set("o_stress", value: high.isEmpty ? nil : String(format: "%.1f", high.reduce(0, +) / Double(high.count)), series: high)
        }
        if let rows = try? await client.dailyCollection("daily_spo2", start: windowStart, end: end) {
            let vals = rows.compactMap { (($0["spo2_percentage"] as? [String: Any])?["average"] as? NSNumber)?.doubleValue }
            set("spo2", value: vals.isEmpty ? nil : String(format: "%.1f", vals.reduce(0, +) / Double(vals.count)), series: vals)
        }
        if let rows = try? await client.dailyCollection("daily_cardiovascular_age", start: windowStart, end: end),
           let vascular = rows.compactMap({ ($0["vascular_age"] as? NSNumber)?.doubleValue }).last {
            if let info = try? await client.personalInfo(),
               let age = (info["age"] as? NSNumber)?.doubleValue {
                set("years", value: String(format: "%+.0f", age - vascular))
            } else {
                set("years", value: String(format: "%.0f", vascular))
            }
        }
    }
}
