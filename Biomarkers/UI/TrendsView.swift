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
    private let colWidth: CGFloat = 84
    private let nameWidth: CGFloat = 130

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
                Text(cell(id: metric.id, week: week) ?? "—")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(cell(id: metric.id, week: week) == nil ? .secondary : .primary)
                    .frame(width: colWidth, height: rowHeight)
                    .overlay(alignment: .bottom) { Divider() }
            }
        }
        .background(index % 2 == 1 ? Color.secondary.opacity(0.06) : Color.clear)
    }

    private func header(_ week: (start: Date, end: Date)) -> String {
        "\(week.start.formatted(.dateTime.month(.abbreviated).day()))–\(week.end.formatted(.dateTime.day()))"
    }

    // MARK: - Cell values

    private func cell(id: String, week: (start: Date, end: Date)) -> String? {
        if DashboardModel.activityMetricIds.contains(id) {
            return activityCell(id: id, week: week)
        }
        return dailyCell(id: id, week: week)
    }

    private func dailyCell(id: String, week: (start: Date, end: Date)) -> String? {
        guard let spec = DashboardModel.specs[id] else { return nil }
        let rows = dailyMetrics.filter { $0.metricKey == id && $0.day >= week.start && $0.day <= week.end }
        guard !rows.isEmpty else { return nil }
        let headline: Double
        switch spec.agg {
        case .avg: headline = rows.map(\.value).reduce(0, +) / Double(rows.count)
        case .latest: headline = rows.max(by: { $0.day < $1.day })?.value ?? 0
        }
        return spec.format(headline)
    }

    private func activityCell(id: String, week: (start: Date, end: Date)) -> String? {
        let endExclusive = cal.date(byAdding: .day, value: 1, to: week.end)!
        let inWeek = activities.filter { $0.startDate >= week.start && $0.startDate < endExclusive }
        guard !inWeek.isEmpty else { return nil }
        switch id {
        case "workout_cal":
            let sum = inWeek.map(\.calories).reduce(0, +)
            return sum > 0 ? String(Int(sum)) : nil
        case "gym":
            let gymKeys = ["strength_training", "fitness_equipment", "indoor_cardio", "hiit", "yoga", "pilates"]
            return String(inWeek.filter { a in gymKeys.contains(where: { a.typeKey.contains($0) }) }.count)
        case "load":
            let sum = inWeek.map(\.trainingLoad).reduce(0, +)
            return sum > 0 ? String(Int(sum)) : nil
        default:
            return nil
        }
    }
}
