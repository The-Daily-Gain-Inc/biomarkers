import SwiftUI
import SwiftData
import Charts

/// Which subset of the HR-zone visuals to render. The Zones tab was retired and
/// its content split across hosts:
/// - `.daily`   → Dashboard "Today" (by-day zones + sleep, this-week, activities)
/// - `.week`    → Dashboard "Last 7 Days" (last-7-days zones, last-7-nights sleep)
/// - `.history` → Trends (all-time zone + sleep breakdowns and trends)
enum ZonesMode { case daily, week, history }

/// Embeddable HR-zone rollup from cached Garmin activities. Renders as card
/// sections so it drops into the Dashboard / Trends ScrollViews. All bucketing
/// is shared through ZoneAggregator, so it's computed once across both hosts.
struct ZoneSectionsView: View {
    let mode: ZonesMode

    @EnvironmentObject var zones: ZoneStore
    @EnvironmentObject var agg: ZoneAggregator
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \CachedActivity.startDate, order: .reverse) private var activities: [CachedActivity]
    @Query private var sleepMetrics: [DailyMetric]
    @State private var weekOffset = 0
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private var cacheSignature: String {
        ZoneAggregator.signature(activities: activities, maxHR: zones.maxHR)
    }

    private func zoneSecs(_ a: CachedActivity) -> [Double] { agg.zoneSecs(a) }

    private var cacheReady: Bool { agg.isReady || activities.isEmpty }

    // MARK: - Derived data

    private var selectedDayZones: [Double] {
        let cal = Calendar.current
        return activities.filter { cal.isDate($0.startDate, inSameDayAs: selectedDay) }
            .reduce(into: [Double](repeating: 0, count: 5)) { acc, a in
                for (i, s) in zoneSecs(a).enumerated() { acc[i] += s }
            }
    }

    private func sleepMinutes(for day: Date) -> [Double] {
        let cal = Calendar.current
        return SleepPalette.keys.map { key in
            sleepMetrics.first { $0.metricKey == key && cal.isDate($0.day, inSameDayAs: day) }?.value ?? 0
        }
    }

    private var weeklySleep: [(date: Date, minutes: [Double])] {
        last7Days.map { ($0, sleepMinutes(for: $0)) }
    }

    private func latestSleepDay() -> Date? {
        sleepMetrics.filter { SleepPalette.keys.contains($0.metricKey) }.map(\.day).max()
    }

    /// The sleep to show for the selected day. Sleep is dated to the morning
    /// you woke, so "today" is last night. Falls back to the most recent night.
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

    private var allTimeZoneTotals: [Double] {
        activities.reduce(into: [Double](repeating: 0, count: 5)) { acc, a in
            for (i, s) in zoneSecs(a).enumerated() { acc[i] += s }
        }
    }

    /// Total minutes per sleep stage (deep, light, rem, awake) across all nights.
    private var allTimeSleepTotals: [Double] {
        SleepPalette.keys.map { key in
            sleepMetrics.filter { $0.metricKey == key }.reduce(0) { $0 + $1.value }
        }
    }

    /// Per-week sleep-stage minutes over the trend window (oldest first).
    private var weeklySleepTrend: [(weekStart: Date, minutes: [Double])] {
        let cal = calendar
        let thisWeekStart = weekInterval.start
        return (0..<trendWeeks).reversed().map { back in
            let start = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeekStart)!
            let interval = cal.dateInterval(of: .weekOfYear, for: start)!
            let mins = SleepPalette.keys.map { key in
                sleepMetrics.filter { $0.metricKey == key && interval.contains($0.day) }
                    .reduce(0) { $0 + $1.value }
            }
            return (interval.start, mins)
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

    // MARK: - Body

    var body: some View {
        VStack(spacing: 14) {
            if !cacheReady {
                card("Heart Rate Zones") {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Crunching your zones…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            } else {
                switch mode {
                case .daily: dailyCards
                case .week: weekCards
                case .history: historyCards
                }
            }
        }
        .padding(.horizontal)
        .task(id: cacheSignature) {
            await agg.rebuild(signature: cacheSignature, activities: activities, floors: zones.floors)
        }
    }

    /// A rounded card matching the grouped-list look, so the charts read the
    /// same as they did in the old Zones tab.
    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Daily (Dashboard)

    @ViewBuilder private var dailyCards: some View {
        card("Heart Rate Zones — By Day") {
            dayNavigator
            Text("Heart Rate Zones").font(.caption).foregroundStyle(.secondary)
            if selectedDayZones.reduce(0, +) > 0 {
                zoneBarChart(selectedDayZones)
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
            if displayedSleep.minutes.reduce(0, +) > 0 {
                sleepBarChart(displayedSleep.minutes)
                sleepLegend
            } else {
                Text("No sleep data that night").font(.footnote).foregroundStyle(.secondary)
            }
        }
        card("Time in Zone (Week)") {
            weekPicker
            zoneBarChart(zoneTotals)
        }
        card("Activities") {
            if weekActivities.isEmpty {
                Text("No activities this week").foregroundStyle(.secondary)
            }
            ForEach(weekActivities) { activity in
                ActivityRow(activity: activity, floors: zones.floors)
                if activity.id != weekActivities.last?.id { Divider() }
            }
        }
    }

    // MARK: - Last 7 (Dashboard "Last 7 Days")

    @ViewBuilder private var weekCards: some View {
        card("HR Zones — Last 7 Days") {
            dailyChart
            zoneLegend
        }
        card("Sleep — Last 7 Nights") {
            weeklySleepChart
            sleepLegend
        }
    }

    // MARK: - History (Trends)

    @ViewBuilder private var historyCards: some View {
        card("Zone Breakdown — All Time") { zonePieChart }
        card("Zone Trend — \(trendWeeks) Weeks") {
            zoneTrendChart
            zoneLegend
            zoneTrendTable
        }
        card("Sleep Breakdown — All Time") { sleepDonut }
        card("Sleep Trend — \(trendWeeks) Weeks") {
            sleepTrendChart
            sleepLegend
        }
    }

    // MARK: - Pieces

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

    /// Stacked minutes-per-zone per week over the trend window.
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

    /// All-time zone split as a donut, with a legend of minutes + percentage.
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

    /// All-time sleep-stage split as a donut, with a legend of time + share
    /// per stage — the sleep counterpart to the zone breakdown.
    private var sleepDonut: some View {
        let totals = allTimeSleepTotals
        let grand = totals.reduce(0, +)
        return Group {
            if grand > 0 {
                Chart(Array(totals.enumerated()), id: \.offset) { item in
                    SectorMark(
                        angle: .value("Minutes", item.element),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(SleepPalette.color(index: item.offset, scheme: scheme))
                }
                .frame(height: 200)
                .padding(.vertical, 4)

                VStack(spacing: 6) {
                    ForEach(Array(totals.enumerated()), id: \.offset) { item in
                        let pct = item.element / grand * 100
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(SleepPalette.color(index: item.offset, scheme: scheme))
                                .frame(width: 10, height: 10)
                            Text(SleepPalette.labels[item.offset]).font(.caption)
                            Spacer()
                            Text(formatDuration(item.element * 60))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(Int(pct.rounded()))%")
                                .font(.caption.weight(.semibold))
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } else {
                Text("No sleep data yet")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
    }

    /// Stacked sleep-stage minutes per week over the trend window.
    private var sleepTrendChart: some View {
        let data = weeklySleepTrend
        let hasData = data.contains { $0.minutes.reduce(0, +) > 0 }
        return Group {
            if hasData {
                Chart {
                    ForEach(Array(data.enumerated()), id: \.offset) { _, week in
                        ForEach(0..<4, id: \.self) { stage in
                            if week.minutes[stage] > 0 {
                                BarMark(
                                    x: .value("Week", week.weekStart, unit: .weekOfYear),
                                    y: .value("Minutes", week.minutes[stage])
                                )
                                .foregroundStyle(SleepPalette.color(index: stage, scheme: scheme))
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
                Text("No sleep data yet")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
    }

    /// Highest zone number (1…5) that has any time in the given week.
    private func topZone(_ zones: [Double]) -> Int {
        (1...5).last { zones[$0 - 1] > 0 } ?? 5
    }

    /// Numeric per-week breakdown: minutes in each zone plus the week total.
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
