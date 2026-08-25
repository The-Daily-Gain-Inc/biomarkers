import SwiftUI
import SwiftData
import Charts

/// Weekly HR-zone rollup from cached Garmin activities — the thing neither
/// Garmin Connect nor Oura will show. ISO weeks (Monday start).
struct WeeklyZonesView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var sync: SyncEngine
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @AppStorage("backfillMonths") private var backfillMonths = 6
    @Query(sort: \CachedActivity.startDate, order: .reverse) private var activities: [CachedActivity]
    @State private var weekOffset = 0

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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    weekPicker
                    zoneChart
                        .listRowSeparator(.hidden)
                } header: {
                    Text("Time in Zone")
                }
                Section {
                    if weekActivities.isEmpty {
                        Text("No activities this week")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(weekActivities) { activity in
                        ActivityRow(activity: activity)
                    }
                } header: {
                    Text("Activities")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text("HR Zones"))
            .refreshable {
                await sync.sync(context: context, session: session, backfillMonths: backfillMonths)
            }
        }
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

    private var zoneChart: some View {
        Chart(Array(zoneTotals.enumerated()), id: \.offset) { item in
            BarMark(
                x: .value("Time", item.element / 60),
                y: .value("Zone", "Z\(item.offset + 1)")
            )
            .foregroundStyle(ZonePalette.color(zone: item.offset + 1, scheme: scheme))
            .cornerRadius(4)
            .annotation(position: .trailing, alignment: .leading) {
                Text(formatDuration(item.element))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel()
            }
        }
        .frame(height: 190)
        .padding(.vertical, 4)
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
