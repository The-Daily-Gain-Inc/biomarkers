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

    /// Per-activity bucketed zone seconds, computed once per (activities, Max HR)
    /// change off the main thread. Every chart sums this instead of re-walking
    /// each activity's HR samples on every body pass.
    @State private var zoneCache: [Int: [Double]] = [:]
    @State private var cacheKey = ""

    /// Signature of the inputs the cache depends on: Max HR, activity count,
    /// and total HR samples (so a backfill of raw HR re-triggers the rebuild).
    private var cacheSignature: String {
        let samples = activities.reduce(0) { $0 + $1.hrBpm.count }
        return "\(zones.maxHR)-\(activities.count)-\(samples)"
    }

    /// Bucketed zone seconds for one activity, from the cache (falls back to
    /// Garmin's split until the cache is built).
    private func zoneSecs(_ a: CachedActivity) -> [Double] {
        zoneCache[a.activityId] ?? a.fiveZoneSeconds
    }

    /// True once the heavy per-activity bucketing has produced results.
    private var cacheReady: Bool { !zoneCache.isEmpty || activities.isEmpty }

    /// HR-zone seconds for the selected day.
    private var selectedDayZones: [Double] {
        let cal = Calendar.current
        return activities.filter { cal.isDate($0.startDate, inSameDayAs: selectedDay) }
            .reduce(into: [Double](repeating: 0, count: 5)) { acc, a in
                for (i, s) in zoneSecs(a).enumerated() { acc[i] += s }
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

    private func latestSleepDay() -> Date? {
        sleepMetrics.filter { SleepPalette.keys.contains($0.metricKey) }.map(\.day).max()
    }

    /// The sleep to show for the selected day. Sleep is dated to the morning
    /// you woke, so "today" is last night. If the selected day has no sleep
    /// (e.g. today's not synced yet), fall back to the most recent night.
    private var displayedSleep: (day: Date, minutes: [Double]) {
        let m = sleepMinutes(for: selectedDay)
        if m.reduce(0, +) > 0 { return (selectedDay, m) }
        if Calendar.current.isDateInToday(selectedDay), let latest = latestSleepDay() {
            return (latest, sleepMinutes(for: latest))
        }
        return (selectedDay, m)
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
            for (i, secs) in zoneSecs(a).enumerated() { acc[i] += secs }
        }
    }

    private var last7Days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).map { cal.date(byAdding: .day, value: -6 + $0, to: today)! }
    }

    /// Total seconds in each zone across every cached activity (all time),
    /// computed against the custom bounds.
    private var allTimeZoneTotals: [Double] {
        activities.reduce(into: [Double](repeating: 0, count: 5)) { acc, a in
            for (i, s) in zoneSecs(a).enumerated() { acc[i] += s }
        }
    }

    /// How many ISO weeks of history to show: back to the oldest activity
    /// (capped at 5 years to stay sane), minimum 12.
    private var trendWeeks: Int {
        let cal = calendar
        guard let oldest = activities.map(\.startDate).min() else { return 12 }
        let weeks = (cal.dateComponents([.weekOfYear],
                     from: cal.dateInterval(of: .weekOfYear, for: oldest)!.start,
                     to: weekInterval.start).weekOfYear ?? 0) + 1
        return min(max(weeks, 12), 260)
    }

    /// Per-week zone seconds over the trend window (oldest first), so the
    /// stacked trend shows how the zone mix shifts over time.
    private var weeklyZoneTrend: [(weekStart: Date, zones: [Double])] {
        let cal = calendar
        let thisWeekStart = weekInterval.start
        return (0..<trendWeeks).reversed().map { back in
            let start = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeekStart)!
            let interval = cal.dateInterval(of: .weekOfYear, for: start)!
            let acts = activities.filter { interval.contains($0.startDate) }
            let z = acts.reduce(into: [Double](repeating: 0, count: 5)) { acc, a in
                for (i, s) in zoneSecs(a).enumerated() { acc[i] += s }
            }
            return (interval.start, z)
        }
    }

    /// Per-day zone seconds for the trailing 7 days (index 0 = oldest).
    private var dailyZoneSeconds: [(date: Date, zones: [Double])] {
        let cal = Calendar.current
        return last7Days.map { day in
            let dayActs = activities.filter { cal.isDate($0.startDate, inSameDayAs: day) }
            let dz = dayActs.reduce(into: [Double](repeating: 0, count: 5)) { acc, a in
                for (i, s) in zoneSecs(a).enumerated() { acc[i] += s }
            }
            return (day, dz)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if cacheReady {
                    content
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Crunching your zones…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(Text("Zones"))
            .task(id: cacheSignature) { await buildCache() }
        }
    }

    private var content: some View {
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
                    HStack {
                        Text("Sleep Stages").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if displayedSleep.minutes.reduce(0, +) > 0 {
                            Text(Calendar.current.isDateInToday(selectedDay)
                                 ? "night of \(displayedSleep.day.formatted(.dateTime.month(.abbreviated).day()))"
                                 : "")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .listRowSeparator(.hidden)
                    if displayedSleep.minutes.reduce(0, +) > 0 {
                        sleepBarChart(displayedSleep.minutes).listRowSeparator(.hidden)
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
                    zonePieChart.listRowSeparator(.hidden)
                } header: {
                    Text("Zone Breakdown — All Time")
                }
                Section {
                    zoneTrendChart.listRowSeparator(.hidden)
                    zoneLegend.listRowSeparator(.hidden)
                    zoneTrendTable.listRowSeparator(.hidden)
                } header: {
                    Text("Zone Trend — \(trendWeeks) Weeks")
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
                        ActivityRow(activity: activity, floors: zones.floors)
                    }
                } header: {
                    Text("Activities")
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await sync.sync(context: context, session: session, backfillMonths: backfillMonths)
            }
    }

    /// Rebuild the per-activity zone cache off the main thread when inputs
    /// change, so the charts never re-walk HR samples during rendering.
    private func buildCache() async {
        guard cacheKey != cacheSignature else { return }
        let floors = zones.floors
        let snaps: [(Int, [Int], [Double], [Double])] =
            activities.map { ($0.activityId, $0.hrBpm, $0.hrElapsed, $0.fiveZoneSeconds) }
        let result = await Task.detached(priority: .userInitiated) { () -> [Int: [Double]] in
            var dict = [Int: [Double]](minimumCapacity: snaps.count)
            for s in snaps {
                dict[s.0] = Self.bucket(bpm: s.1, elapsed: s.2, floors: floors, fallback: s.3)
            }
            return dict
        }.value
        zoneCache = result
        cacheKey = cacheSignature
    }

    /// Time-in-zone from a raw HR series against `floors`; mirrors
    /// CachedActivity.zoneSeconds(floors:) but runs on a Sendable snapshot.
    nonisolated static func bucket(bpm: [Int], elapsed: [Double],
                                   floors: [Int], fallback: [Double]) -> [Double] {
        guard !bpm.isEmpty, floors.count == 5 else { return fallback }
        var out = [Double](repeating: 0, count: 5)
        for i in bpm.indices {
            let hr = bpm[i]
            guard hr >= floors[0] else { continue }
            var zone = 0
            for z in 0..<5 where hr >= floors[z] { zone = z }
            let dwell = i + 1 < elapsed.count ? min(max(elapsed[i + 1] - elapsed[i], 0), 120) : 1
            out[zone] += dwell
        }
        return out
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

    /// Stacked minutes-per-zone per week over the trend window, so the shifting
    /// zone mix (how much time in each zone) reads at a glance.
    private var zoneTrendChart: some View {
        let data = weeklyZoneTrend
        let hasData = data.contains { $0.zones.reduce(0, +) > 0 }
        return Group {
            if hasData {
                Chart {
                    ForEach(Array(data.enumerated()), id: \.offset) { _, week in
                        ForEach(1...5, id: \.self) { zone in
                            let mins = week.zones[zone - 1] / 60
                            if mins > 0 {
                                BarMark(
                                    x: .value("Week", week.weekStart, unit: .weekOfYear),
                                    y: .value("Minutes", mins)
                                )
                                .foregroundStyle(ZonePalette.color(zone: zone, scheme: scheme))
                                .annotation(position: .top) {
                                    // Total for the week, drawn once (on the top-most zone present).
                                    if zone == topZone(week.zones) {
                                        Text("\(Int((week.zones.reduce(0, +) / 60).rounded()))")
                                            .font(.system(size: 8)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: max(1, trendWeeks / 8))) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 190)
                .padding(.vertical, 4)
            } else {
                Text("No zone data yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
    }

    /// All-time zone split as a donut, with each slice's share of total time
    /// and a legend of minutes + percentage per zone.
    private var zonePieChart: some View {
        let totals = allTimeZoneTotals
        let grand = totals.reduce(0, +)
        return Group {
            if grand > 0 {
                Chart(Array(totals.enumerated()), id: \.offset) { item in
                    SectorMark(
                        angle: .value("Time", item.element),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(ZonePalette.color(zone: item.offset + 1, scheme: scheme))
                }
                .frame(height: 200)
                .padding(.vertical, 4)

                VStack(spacing: 6) {
                    ForEach(Array(totals.enumerated()), id: \.offset) { item in
                        let pct = item.element / grand * 100
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ZonePalette.color(zone: item.offset + 1, scheme: scheme))
                                .frame(width: 10, height: 10)
                            Text("Z\(item.offset + 1)").font(.caption).frame(width: 22, alignment: .leading)
                            Text(zones.rangeLabel(zone: item.offset + 1) + " bpm")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text(formatDuration(item.element))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(Int(pct.rounded()))%")
                                .font(.caption.weight(.semibold))
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } else {
                Text("No zone data yet")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
    }

    /// Highest zone number (1…5) that has any time in the given week.
    private func topZone(_ zones: [Double]) -> Int {
        (1...5).last { zones[$0 - 1] > 0 } ?? 5
    }

    /// Numeric per-week breakdown: minutes in each zone plus the week total,
    /// newest week first.
    private var zoneTrendTable: some View {
        let rows = weeklyZoneTrend.reversed().filter { $0.zones.reduce(0, +) > 0 }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Week").font(.system(size: 10, weight: .semibold))
                    .frame(width: 56, alignment: .leading)
                ForEach(1...5, id: \.self) { z in
                    Text("Z\(z)").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ZonePalette.color(zone: z, scheme: scheme))
                        .frame(maxWidth: .infinity)
                }
                Text("Tot").font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    Text(week.weekStart.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    ForEach(1...5, id: \.self) { z in
                        Text(minsLabel(week.zones[z - 1]))
                            .font(.system(size: 10, design: .rounded))
                            .frame(maxWidth: .infinity)
                    }
                    Text(minsLabel(week.zones.reduce(0, +)))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 3)
                Divider()
            }
        }
    }

    /// Whole minutes for a seconds value, or "—" when zero.
    private func minsLabel(_ seconds: Double) -> String {
        seconds > 0 ? "\(Int((seconds / 60).rounded()))" : "—"
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
    var floors: [Int] = []
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
        let zones = activity.zoneSeconds(floors: floors)
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
