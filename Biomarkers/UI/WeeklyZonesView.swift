import SwiftUI
import SwiftData
import Charts

/// Weekly HR-zone rollup from cached Garmin activities — the thing neither
/// Garmin Connect nor Oura will show. ISO weeks (Monday start).
struct WeeklyZonesView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var sync: SyncEngine
    @EnvironmentObject var zones: ZoneStore
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @AppStorage("backfillMonths") private var backfillMonths = 6
    @Query(sort: \CachedActivity.startDate, order: .reverse) private var activities: [CachedActivity]
    @Query private var sleepMetrics: [DailyMetric]
    @State private var weekOffset = 0
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    /// HR-zone seconds for the selected day.
    private var selectedDayZones: [Double] {
        let cal = Calendar.current
        return activities.filter { cal.isDate($0.startDate, inSameDayAs: selectedDay) }
            .reduce(into: [Double](repeating: 0, count: 5)) { acc, a in
                for (i, s) in a.fiveZoneSeconds.enumerated() { acc[i] += s }
            }
    }

    /// Sleep-stage minutes (deep, light, rem, awake) for the selected day.
    private func sleepMinutes(for day: Date) -> [Double] {
        let cal = Calendar.current
        return SleepPalette.keys.map { key in
            sleepMetrics.first { $0.metricKey == key && cal.isDate($0.day, inSameDayAs: day) }?.value ?? 0
        }
    }

    /// Per-night sleep-stage minutes for the trailing 7 days.
    private var weeklySleep: [(date: Date, minutes: [Double])] {
        last7Days.map { ($0, sleepMinutes(for: $0)) }
    }


    private var calendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        return cal
    }

    private var weekInterval: DateInterval {
        let now = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: Date())!
        return calendar.dateInterval(of: .weekOfYear, for: now)!
    }

    private var weekActivities: [CachedActivity] {
        activities.filter { weekInterval.contains($0.startDate) }
    }

    private var zoneTotals: [Double] {
        weekActivities.reduce(into: [Double](repeating: 0, count: 5)) { acc, a in
            for (i, secs) in a.fiveZoneSeconds.enumerated() { acc[i] += secs }
        }
    }

    private var last7Days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).map { cal.date(byAdding: .day, value: -6 + $0, to: today)! }
    }

    /// Per-day zone seconds for the trailing 7 days (index 0 = oldest).
    private var dailyZoneSeconds: [(date: Date, zones: [Double])] {
        let cal = Calendar.current
        return last7Days.map { day in
            let dayActs = activities.filter { cal.isDate($0.startDate, inSameDayAs: day) }
            let zones = dayActs.reduce(into: [Double](repeating: 0, count: 5)) { acc, a in
                for (i, s) in a.fiveZoneSeconds.enumerated() { acc[i] += s }
            }
            return (day, zones)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    dayNavigator
                    Text("Heart Rate Zones").font(.caption).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                    if selectedDayZones.reduce(0, +) > 0 {
                        zoneBarChart(selectedDayZones).listRowSeparator(.hidden)
                    } else {
                        Text("No workout that day").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Sleep Stages").font(.caption).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                    if sleepMinutes(for: selectedDay).reduce(0, +) > 0 {
                        sleepBarChart(sleepMinutes(for: selectedDay)).listRowSeparator(.hidden)
                        sleepLegend.listRowSeparator(.hidden)
                    } else {
                        Text("No sleep data that night").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("By Day")
                }
                Section {
                    dailyChart.listRowSeparator(.hidden)
                    zoneLegend.listRowSeparator(.hidden)
                } header: {
                    Text("HR Zones — Last 7 Days")
                }
                Section {
                    weeklySleepChart.listRowSeparator(.hidden)
                    sleepLegend.listRowSeparator(.hidden)
                } header: {
                    Text("Sleep — Last 7 Nights")
                }
                Section {
                    weekPicker
                    zoneBarChart(zoneTotals).listRowSeparator(.hidden)
                } header: {
                    Text("Time in Zone (Week)")
                }
                Section {
                    if weekActivities.isEmpty {
                        Text("No activities this week").foregroundStyle(.secondary)
                    }
                    ForEach(weekActivities) { activity in
                        ActivityRow(activity: activity)
                    }
                } header: {
                    Text("Activities")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text("Zones"))
            .refreshable {
                await sync.sync(context: context, session: session, backfillMonths: backfillMonths)
            }
        }
    }

    private var dayNavigator: some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(selectedDay)
        return HStack {
            Button { selectedDay = cal.date(byAdding: .day, value: -1, to: selectedDay)! } label: {
                Image(systemName: "chevron.left")
            }.buttonStyle(.borderless)
            Spacer()
            Text(isToday ? String(localized: "Today")
                 : selectedDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.headline)
            Spacer()
            Button { selectedDay = cal.date(byAdding: .day, value: 1, to: selectedDay)! } label: {
                Image(systemName: "chevron.right")
            }.buttonStyle(.borderless).disabled(isToday)
        }
    }

    /// Weekly sleep stages, stacked per night.
    private var weeklySleepChart: some View {
        let data = weeklySleep
        let hasData = data.contains { $0.minutes.reduce(0, +) > 0 }
        return Group {
            if hasData {
                Chart {
                    ForEach(Array(data.enumerated()), id: \.offset) { _, night in
                        ForEach(0..<4, id: \.self) { stage in
                            if night.minutes[stage] > 0 {
                                BarMark(
                                    x: .value("Night", night.date, unit: .day),
                                    y: .value("Minutes", night.minutes[stage])
                                )
                                .foregroundStyle(SleepPalette.color(index: stage, scheme: scheme))
                            }
                        }
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                .frame(height: 170)
            } else {
                Text("No sleep data in the last 7 nights")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
    }

    /// Horizontal bar chart of HR-zone time (seconds per zone).
    private func zoneBarChart(_ secondsPerZone: [Double]) -> some View {
        Chart(Array(secondsPerZone.enumerated()), id: \.offset) { item in
            BarMark(x: .value("Time", item.element / 60), y: .value("Zone", "Z\(item.offset + 1)"))
                .foregroundStyle(ZonePalette.color(zone: item.offset + 1, scheme: scheme))
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(formatDuration(item.element)).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { _ in AxisValueLabel() } }
        .frame(height: 170).padding(.vertical, 4)
    }

    /// Horizontal bar chart of sleep-stage minutes.
    private func sleepBarChart(_ minutesPerStage: [Double]) -> some View {
        Chart(Array(minutesPerStage.enumerated()), id: \.offset) { item in
            BarMark(x: .value("Minutes", item.element), y: .value("Stage", SleepPalette.labels[item.offset]))
                .foregroundStyle(SleepPalette.color(index: item.offset, scheme: scheme))
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(formatDuration(item.element * 60)).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { _ in AxisValueLabel() } }
        .frame(height: 150).padding(.vertical, 4)
    }

    /// Stacked minutes-per-zone for each of the last 7 days.
    private var dailyChart: some View {
        let data = dailyZoneSeconds
        let hasData = data.contains { $0.zones.reduce(0, +) > 0 }
        return Group {
            if hasData {
                Chart {
                    ForEach(Array(data.enumerated()), id: \.offset) { _, day in
                        ForEach(1...5, id: \.self) { zone in
                            let mins = day.zones[zone - 1] / 60
                            if mins > 0 {
                                BarMark(
                                    x: .value("Day", day.date, unit: .day),
                                    y: .value("Minutes", mins)
                                )
                                .foregroundStyle(ZonePalette.color(zone: zone, scheme: scheme))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .frame(height: 170)
                .padding(.vertical, 4)
            } else {
                Text("No zone data in the last 7 days")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
    }

    /// Last night's sleep stages as a horizontal bar chart, mirroring the
    /// activity zone chart.

    private var sleepLegend: some View {
        HStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { i in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SleepPalette.color(index: i, scheme: scheme))
                        .frame(width: 10, height: 10)
                    Text(SleepPalette.labels[i]).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var zoneLegend: some View {
        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { zone in
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(ZonePalette.color(zone: zone, scheme: scheme))
                            .frame(width: 10, height: 10)
                        Text("Z\(zone)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(zones.rangeLabel(zone: zone))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var weekPicker: some View {
        HStack {
            Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Spacer()
            VStack(spacing: 2) {
                Text(weekOffset == 0
                     ? String(localized: "This Week")
                     : weekInterval.start.formatted(.dateTime.month(.abbreviated).day()) + " – "
                       + calendar.date(byAdding: .day, value: 6, to: weekInterval.start)!
                           .formatted(.dateTime.month(.abbreviated).day()))
                    .font(.headline)
                Text("Total \(formatDuration(zoneTotals.reduce(0, +)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(weekOffset >= 0)
        }
    }

}

struct ActivityRow: View {
    let activity: CachedActivity
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(activity.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(formatDuration(activity.durationSec))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(activity.startDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                .font(.caption2)
                .foregroundStyle(.secondary)
            zoneBar
        }
        .padding(.vertical, 2)
    }

    /// Proportional stacked zone strip with 2px gaps between segments.
    private var zoneBar: some View {
        let zones = activity.fiveZoneSeconds
        let total = zones.reduce(0, +)
        return GeometryReader { geo in
            HStack(spacing: 2) {
                if total > 0 {
                    ForEach(0..<5, id: \.self) { i in
                        if zones[i] > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ZonePalette.color(zone: i + 1, scheme: scheme))
                                .frame(width: max(geo.size.width * zones[i] / total - 2, 2))
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                }
            }
        }
        .frame(height: 6)
    }
}
