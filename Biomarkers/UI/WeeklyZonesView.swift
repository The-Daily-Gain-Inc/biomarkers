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
    /// Only the four sleep-stage rows — the whole DailyMetric table used to
    /// be fetched (and re-fetched on every change) for these.
    @Query private var sleepMetrics: [DailyMetric]
    @State private var weekOffset = 0
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Every series the cards draw, computed once off the main thread per
    /// data change. The computed properties below used to walk every
    /// activity and every sleep row (up to 260 weeks × all rows) on each
    /// render — that was the Dashboard's stutter.
    @State private var derived: ZoneDerived?

    init(mode: ZonesMode) {
        self.mode = mode
        let keys = SleepPalette.keys
        _sleepMetrics = Query(filter: #Predicate<DailyMetric> { keys.contains($0.metricKey) })
    }

    private var cacheSignature: String {
        ZoneAggregator.signature(activities: activities, maxHR: zones.maxHR)
    }

    /// Cheap key for re-deriving: counts and versions only, no row reads.
    private var derivedKey: String {
        "\(activities.count)-\(sleepMetrics.count)-\(agg.version)-\(zones.maxHR)-\(weekOffset)-\(Int(selectedDay.timeIntervalSince1970))"
    }

    private var cacheReady: Bool { derived != nil && (agg.isReady || activities.isEmpty) }

    private func recompute() async {
        let snapActs = activities.map { ZoneDerived.Act(id: $0.activityId, start: $0.startDate, zones: agg.zoneSecs($0)) }
        let snapSleep = sleepMetrics.map { ZoneDerived.Sleep(key: $0.metricKey, day: $0.day, value: $0.value) }
        let input = ZoneDerived.Input(acts: snapActs, sleep: snapSleep,
                                      selectedDay: selectedDay, weekInterval: weekInterval,
                                      calendar: calendar, last7Days: last7Days)
        let result = await Task.detached(priority: .userInitiated) { ZoneDerived.compute(input) }.value
        derived = result
    }

    // MARK: - Derived data (read from `derived`; see ZoneDerived.compute)

    private static let zeros5 = [Double](repeating: 0, count: 5)

    private var selectedDayZones: [Double] { derived?.selectedDayZones ?? Self.zeros5 }
    private var displayedSleep: (day: Date, minutes: [Double]) { derived?.displayedSleep ?? (selectedDay, [0, 0, 0, 0]) }
    private var weeklySleep: [(date: Date, minutes: [Double])] { derived?.weeklySleep ?? [] }
    private var zoneTotals: [Double] { derived?.zoneTotals ?? Self.zeros5 }
    private var allTimeZoneTotals: [Double] { derived?.allTimeZoneTotals ?? Self.zeros5 }
    private var allTimeSleepTotals: [Double] { derived?.allTimeSleepTotals ?? [0, 0, 0, 0] }
    private var weeklySleepTrend: [(weekStart: Date, minutes: [Double])] { derived?.weeklySleepTrend ?? [] }
    private var trendWeeks: Int { derived?.trendWeeks ?? 12 }
    private var weeklyZoneTrend: [(weekStart: Date, zones: [Double])] { derived?.weeklyZoneTrend ?? [] }
    private var dailyZoneSeconds: [(date: Date, zones: [Double])] { derived?.dailyZoneSeconds ?? [] }

    /// This week's activities, newest first (the query order).
    private var weekActivities: [CachedActivity] {
        guard let ids = derived?.weekActivityIds, !ids.isEmpty else { return [] }
        let set = Set(ids)
        return activities.filter { set.contains($0.activityId) }
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

    private var last7Days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).map { cal.date(byAdding: .day, value: -6 + $0, to: today)! }
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
        .task(id: derivedKey) { await recompute() }
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
                ActivityRow(activity: activity, zones: agg.zoneSecs(activity))
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
    /// Bucketed seconds per zone (from ZoneAggregator's cache), so the row
    /// doesn't re-walk the raw HR series on every render.
    var zones: [Double] = []
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
        let zones = self.zones.count == 5 ? self.zones : activity.fiveZoneSeconds
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


/// Everything ZoneSectionsView draws, computed from plain snapshots on a
/// background thread. Bucketing by day/week is done with dictionaries, not a
/// filter over all rows per bucket.
struct ZoneDerived: Sendable {
    struct Act: Sendable { let id: Int; let start: Date; let zones: [Double] }
    struct Sleep: Sendable { let key: String; let day: Date; let value: Double }
    struct Input: Sendable {
        let acts: [Act]
        let sleep: [Sleep]
        let selectedDay: Date
        let weekInterval: DateInterval
        let calendar: Calendar
        let last7Days: [Date]
    }

    var selectedDayZones: [Double] = zeros5
    var displayedSleep: (day: Date, minutes: [Double]) = (Date(), [0, 0, 0, 0])
    var weeklySleep: [(date: Date, minutes: [Double])] = []
    var weekActivityIds: [Int] = []
    var zoneTotals: [Double] = zeros5
    var allTimeZoneTotals: [Double] = zeros5
    var allTimeSleepTotals: [Double] = [0, 0, 0, 0]
    var weeklySleepTrend: [(weekStart: Date, minutes: [Double])] = []
    var trendWeeks = 12
    var weeklyZoneTrend: [(weekStart: Date, zones: [Double])] = []
    var dailyZoneSeconds: [(date: Date, zones: [Double])] = []

    static let zeros5 = [Double](repeating: 0, count: 5)

    static func compute(_ input: Input) -> ZoneDerived {
        var out = ZoneDerived()
        let cal = input.calendar          // ISO week calendar
        let dayCal = Calendar.current
        let keys = SleepPalette.keys
        let stage: [String: Int] = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })

        func add(_ acc: inout [Double], _ z: [Double]) {
            for (i, s) in z.enumerated() where i < 5 { acc[i] += s }
        }

        // Activities bucketed by start-of-day and by ISO week start.
        var byDay: [Date: [Double]] = [:]
        var byWeek: [Date: [Double]] = [:]
        var all = zeros5
        var weekIds: [Int] = []
        var weekTotals = zeros5
        var oldest: Date?
        for a in input.acts {
            add(&all, a.zones)
            byDay[dayCal.startOfDay(for: a.start), default: zeros5] = {
                var z = byDay[dayCal.startOfDay(for: a.start)] ?? zeros5; add(&z, a.zones); return z }()
            let ws = cal.dateInterval(of: .weekOfYear, for: a.start)?.start ?? a.start
            byWeek[ws] = { var z = byWeek[ws] ?? zeros5; add(&z, a.zones); return z }()
            if input.weekInterval.contains(a.start) { weekIds.append(a.id); add(&weekTotals, a.zones) }
            if oldest == nil || a.start < oldest! { oldest = a.start }
        }
        out.allTimeZoneTotals = all
        out.weekActivityIds = weekIds
        out.zoneTotals = weekTotals
        out.selectedDayZones = byDay[dayCal.startOfDay(for: input.selectedDay)] ?? zeros5
        out.dailyZoneSeconds = input.last7Days.map { ($0, byDay[dayCal.startOfDay(for: $0)] ?? zeros5) }

        // Sleep stages bucketed by day and by ISO week start.
        var sleepByDay: [Date: [Double]] = [:]
        var sleepByWeek: [Date: [Double]] = [:]
        var sleepAll = [0.0, 0.0, 0.0, 0.0]
        var latestSleepDay: Date?
        for s in input.sleep {
            guard let i = stage[s.key] else { continue }
            let d = dayCal.startOfDay(for: s.day)
            var m = sleepByDay[d] ?? [0, 0, 0, 0]; m[i] += s.value; sleepByDay[d] = m
            let ws = cal.dateInterval(of: .weekOfYear, for: s.day)?.start ?? s.day
            var w = sleepByWeek[ws] ?? [0, 0, 0, 0]; w[i] += s.value; sleepByWeek[ws] = w
            sleepAll[i] += s.value
            if latestSleepDay == nil || s.day > latestSleepDay! { latestSleepDay = s.day }
        }
        out.allTimeSleepTotals = sleepAll
        func sleepMinutes(_ day: Date) -> [Double] { sleepByDay[dayCal.startOfDay(for: day)] ?? [0, 0, 0, 0] }
        out.weeklySleep = input.last7Days.map { ($0, sleepMinutes($0)) }
        let selectedSleep = sleepMinutes(input.selectedDay)
        if selectedSleep.reduce(0, +) > 0 {
            out.displayedSleep = (input.selectedDay, selectedSleep)
        } else if dayCal.isDateInToday(input.selectedDay), let latest = latestSleepDay {
            out.displayedSleep = (latest, sleepMinutes(latest))
        } else {
            out.displayedSleep = (input.selectedDay, selectedSleep)
        }

        // Trend window: back to the oldest activity, 12…260 weeks.
        let thisWeekStart = input.weekInterval.start
        var weeks = 12
        if let oldest, let oldestWeek = cal.dateInterval(of: .weekOfYear, for: oldest)?.start {
            weeks = (cal.dateComponents([.weekOfYear], from: oldestWeek, to: thisWeekStart).weekOfYear ?? 0) + 1
        }
        weeks = min(max(weeks, 12), 260)
        out.trendWeeks = weeks
        var zoneTrend: [(weekStart: Date, zones: [Double])] = []
        var sleepTrend: [(weekStart: Date, minutes: [Double])] = []
        for back in (0..<weeks).reversed() {
            guard let start = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeekStart),
                  let ws = cal.dateInterval(of: .weekOfYear, for: start)?.start else { continue }
            zoneTrend.append((ws, byWeek[ws] ?? zeros5))
            sleepTrend.append((ws, sleepByWeek[ws] ?? [0, 0, 0, 0]))
        }
        out.weeklyZoneTrend = zoneTrend
        out.weeklySleepTrend = sleepTrend
        return out
    }
}
