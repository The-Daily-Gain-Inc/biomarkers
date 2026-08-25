import SwiftUI
import SwiftData

/// Week-over-week matrix: one row per stat, one column per trailing 7-day
/// period (newest on the left). Cells are computed from the SwiftData cache,
/// so scrolling back through weeks needs no extra network once fetched.
struct TrendsView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var ouraSession: OuraSession
    @Environment(\.modelContext) private var context
    @StateObject private var model = DashboardModel()
    @Query private var dailyMetrics: [DailyMetric]
    @Query private var activities: [CachedActivity]
    @AppStorage("weeksOfHistory") private var weeksOfHistory = 6

    private let rowHeight: CGFloat = 44
    private let colWidth: CGFloat = 92
    private let nameWidth: CGFloat = 122

    /// Whether a higher value is the healthier direction for each metric.
    /// Used to color the week-over-week arrow green (better) or red (worse).
    private static let higherIsBetter: [String: Bool] = [
        "workout_cal": true, "gym": true, "vo2": true, "fit_age": false,
        "load": true, "rhr": false, "stress": false, "steps": true,
        "o_hrv": true, "o_stress": false, "o_activity": true, "spo2": true,
        "years": true, "sleep_score": true, "sleep_hours": true,
    ]

    private var cal: Calendar { Calendar.current }

    /// Week windows, newest first: (start, endInclusive).
    private var weeks: [(start: Date, end: Date)] {
        let today = cal.startOfDay(for: Date())
        return (0..<weeksOfHistory).map { k in
            let end = cal.date(byAdding: .day, value: -7 * k, to: today)!
            let start = cal.date(byAdding: .day, value: -6, to: end)!
            return (start, end)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    frozenColumn
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 0) {
                            ForEach(Array(weeks.enumerated()), id: \.offset) { idx, week in
                                weekColumn(index: idx, week: week)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle(Text("Trends"))
            .task { await model.loadHistory(context: context, garmin: session, oura: ouraSession, weeks: weeksOfHistory) }
            .refreshable { await model.loadHistory(context: context, garmin: session, oura: ouraSession, weeks: weeksOfHistory) }
            .overlay(alignment: .top) {
                if model.isLoadingHistory {
                    ProgressView().padding(.top, 6)
                }
            }
        }
    }

    private var frozenColumn: some View {
        VStack(spacing: 0) {
            Text("Stat")
                .font(.caption.weight(.semibold))
                .frame(width: nameWidth, height: rowHeight, alignment: .leading)
            ForEach(DashboardModel.placeholders) { metric in
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(metric.titleKey))
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private func weekColumn(index: Int, week: (start: Date, end: Date)) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(index == 0 ? String(localized: "This wk") : header(week))
                    .font(.caption2.weight(.semibold))
                Text(week.start.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(width: colWidth, height: rowHeight)
            ForEach(DashboardModel.placeholders) { metric in
                cellView(id: metric.id, index: index, week: week)
                    .frame(width: colWidth, height: rowHeight)
                    .overlay(alignment: .bottom) { Divider() }
            }
        }
        .background(index % 2 == 1 ? Color.secondary.opacity(0.06) : Color.clear)
    }

    private func header(_ week: (start: Date, end: Date)) -> String {
        "\(week.start.formatted(.dateTime.month(.abbreviated).day()))–\(week.end.formatted(.dateTime.day()))"
    }

    // MARK: - Cell rendering

    @ViewBuilder
    private func cellView(id: String, index: Int, week: (start: Date, end: Date)) -> some View {
        let value = numericValue(id: id, week: week)
        HStack(spacing: 3) {
            Text(value.map { formatted(id: id, $0) } ?? "—")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(value == nil ? .secondary : .primary)
            indicator(id: id, index: index, current: value)
        }
    }

    /// Green/red up/down arrow comparing this week to the prior (older) week.
    @ViewBuilder
    private func indicator(id: String, index: Int, current: Double?) -> some View {
        let prevWeek = index + 1 < weeks.count ? weeks[index + 1] : nil
        if let current, let prevWeek, let prev = numericValue(id: id, week: prevWeek), current != prev {
            let up = current > prev
            let better = (Self.higherIsBetter[id] ?? true) == up
            Image(systemName: up ? "arrow.up" : "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(better ? Color.green : Color.red)
        }
    }

    private func formatted(id: String, _ value: Double) -> String {
        if let spec = DashboardModel.specs[id] { return spec.format(value) }
        return String(Int(value))   // activity metrics
    }

    // MARK: - Cell values

    private func numericValue(id: String, week: (start: Date, end: Date)) -> Double? {
        if DashboardModel.activityMetricIds.contains(id) {
            return activityValue(id: id, week: week)
        }
        return dailyValue(id: id, week: week)
    }

    private func dailyValue(id: String, week: (start: Date, end: Date)) -> Double? {
        guard let spec = DashboardModel.specs[id] else { return nil }
        let rows = dailyMetrics.filter { $0.metricKey == id && $0.day >= week.start && $0.day <= week.end }
        guard !rows.isEmpty else { return nil }
        switch spec.agg {
        case .avg: return rows.map(\.value).reduce(0, +) / Double(rows.count)
        case .latest: return rows.max(by: { $0.day < $1.day })?.value
        }
    }

    private func activityValue(id: String, week: (start: Date, end: Date)) -> Double? {
        let endExclusive = cal.date(byAdding: .day, value: 1, to: week.end)!
        let inWeek = activities.filter { $0.startDate >= week.start && $0.startDate < endExclusive }
        guard !inWeek.isEmpty else { return nil }
        switch id {
        case "workout_cal":
            let sum = inWeek.map(\.calories).reduce(0, +)
            return sum > 0 ? sum : nil
        case "gym":
            let gymKeys = ["strength_training", "fitness_equipment", "indoor_cardio", "hiit", "yoga", "pilates"]
            return Double(inWeek.filter { a in gymKeys.contains(where: { a.typeKey.contains($0) }) }.count)
        case "load":
            let sum = inWeek.map(\.trainingLoad).reduce(0, +)
            return sum > 0 ? sum : nil
        default:
            return nil
        }
    }
}
