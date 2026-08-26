import SwiftUI
import SwiftData
import Charts

/// In-depth view for a single metric: latest value, a history chart over a
/// selectable range, summary statistics, and recent entries. Works for both
/// cached daily metrics and activity-derived metrics.
struct MetricDetailView: View {
    let id: String

    @Query(sort: \DailyMetric.day) private var dailyMetrics: [DailyMetric]
    @Query(sort: \CachedActivity.startDate) private var activities: [CachedActivity]
    @State private var range: Range = .month

    enum Range: String, CaseIterable {
        case week = "1W", month = "1M", quarter = "3M", year = "1Y", all = "All"
        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            case .year: return 365
            case .all: return nil
            }
        }
    }

    private var meta: Metric? { DashboardModel.placeholders.first { $0.id == id } }
    private var tint: Color { DashboardModel.tint(for: id) }
    private var higherIsBetter: Bool { DashboardModel.higherIsBetter[id] ?? true }

    private func format(_ v: Double) -> String {
        if let f = DashboardModel.specs[id]?.format { return f(v) }
        return String(Int(v.rounded()))
    }

    // MARK: - Series

    /// (day, value) for this metric across all history, oldest first.
    private var fullSeries: [(date: Date, value: Double)] {
        if DashboardModel.activityMetricIds.contains(id) {
            let cal = Calendar.current
            var byDay: [Date: [CachedActivity]] = [:]
            for a in activities { byDay[cal.startOfDay(for: a.startDate), default: []].append(a) }
            let gymKeys = ["strength_training", "fitness_equipment", "indoor_cardio", "hiit", "yoga", "pilates"]
            return byDay.keys.sorted().compactMap { day in
                let acts = byDay[day] ?? []
                let v: Double
                switch id {
                case "workout_cal": v = acts.map(\.calories).reduce(0, +)
                case "gym": v = Double(acts.filter { a in gymKeys.contains { a.typeKey.contains($0) } }.count)
                case "load": v = acts.map(\.trainingLoad).reduce(0, +)
                default: v = 0
                }
                return v > 0 ? (day, v) : nil
            }
        }
        return dailyMetrics.filter { $0.metricKey == id }.map { ($0.day, $0.value) }
    }

    private var series: [(date: Date, value: Double)] {
        guard let days = range.days else { return fullSeries }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return fullSeries.filter { $0.date >= cutoff }
    }

    var body: some View {
        List {
            Section { header }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            Section {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                chart
                    .frame(height: 200)
                    .padding(.vertical, 4)
            }
            .swipeSegments($range)

            Section("Summary") { summary }

            Section("Analysis") {
                Text(analysis).font(.callout)
            }

            if !series.isEmpty {
                Section("Recent") {
                    ForEach(series.suffix(14).reversed(), id: \.date) { point in
                        HStack {
                            Text(point.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(format(point.value)).font(.system(.body, design: .rounded))
                        }
                    }
                }
            }
        }
        .navigationTitle(Text(LocalizedStringKey(meta?.titleKey ?? id)))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(series.last.map { format($0.value) } ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                if let unit = meta?.unit { Text(LocalizedStringKey(unit)).font(.title3).foregroundStyle(.secondary) }
                Spacer()
                if let p = meta?.provider.rawValue {
                    Text(p).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(tint.opacity(0.15), in: Capsule()).foregroundStyle(tint)
                }
            }
            if let last = series.last?.date {
                Text("as of \(last.formatted(.dateTime.month(.abbreviated).day().year()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var chart: some View {
        if series.count >= 2 {
            Chart(series, id: \.date) { point in
                AreaMark(x: .value("Date", point.date), y: .value("Value", point.value))
                    .foregroundStyle(.linearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: yDomain)
        } else {
            Text("Not enough data for this range")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private var summary: some View {
        let vals = series.map(\.value)
        let latest = vals.last
        let avg = vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        let delta: Double? = (vals.count >= 2) ? (vals.last! - vals.first!) : nil
        return VStack(spacing: 0) {
            HStack {
                statCell("Latest", latest.map(format))
                statCell("Average", avg.map(format))
            }
            Divider().padding(.vertical, 6)
            HStack {
                statCell("Min", vals.min().map(format))
                statCell("Max", vals.max().map(format))
            }
            if let delta {
                Divider().padding(.vertical, 6)
                HStack {
                    Text("Change over \(range.rawValue)").foregroundStyle(.secondary)
                    Spacer()
                    let up = delta > 0
                    let better = higherIsBetter == up
                    HStack(spacing: 4) {
                        Image(systemName: up ? "arrow.up" : (delta < 0 ? "arrow.down" : "minus"))
                        Text(format(abs(delta)))
                    }
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(delta == 0 ? .secondary : (better ? Color.green : Color.red))
                }
            }
        }
    }

    private func statCell(_ label: String, _ value: String?) -> some View {
        VStack(spacing: 2) {
            Text(value ?? "—").font(.system(.title3, design: .rounded, weight: .semibold))
            Text(LocalizedStringKey(label)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// A short natural-language read on the range's trend and where the
    /// latest value sits relative to the average.
    private var analysis: String {
        let vals = series.map(\.value)
        guard let latest = vals.last, vals.count >= 2 else {
            return "Not enough data in this range to analyze — log or sync more to see a trend."
        }
        let name = String(localized: String.LocalizationValue(meta?.titleKey ?? id))
        let first = vals.first!
        let avg = vals.reduce(0, +) / Double(vals.count)
        let delta = latest - first
        let dir = delta > 0 ? "up" : (delta < 0 ? "down" : "flat")
        let better = higherIsBetter == (delta > 0)
        let pct = first != 0 ? abs(delta / first) * 100 : 0

        var parts: [String] = []
        if delta == 0 {
            parts.append("\(name) is flat over \(range.rawValue).")
        } else {
            let quality = better ? "an improvement" : "worth watching"
            parts.append("\(name) is \(dir) \(format(abs(delta))) (\(Int(pct))%) over \(range.rawValue) — \(quality).")
        }
        let vsAvg = latest - avg
        if abs(vsAvg) >= max(avg * 0.02, 0.1) {
            let side = vsAvg > 0 ? "above" : "below"
            parts.append("The latest reading is \(side) the \(range.rawValue) average of \(format(avg)).")
        } else {
            parts.append("The latest reading is right around the \(range.rawValue) average.")
        }
        return parts.joined(separator: " ")
    }

    private var yDomain: ClosedRange<Double> {
        let vals = series.map(\.value)
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let pad = max((hi - lo) * 0.12, 0.5)
        return (lo - pad)...(hi + pad)
    }
}
