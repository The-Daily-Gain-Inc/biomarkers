import SwiftUI
import SwiftData

/// Week-over-week matrix: one row per stat, one column per trailing 7-day
/// period (newest on the left). Cells are computed from the SwiftData cache,
/// so scrolling back through weeks needs no extra network once fetched.
struct TrendsView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var ouraSession: OuraSession
    @EnvironmentObject var renphoSession: RenphoSession
    @Environment(\.modelContext) private var context
    @EnvironmentObject var model: DashboardModel
    @AppStorage("weeksOfHistory") private var weeksOfHistory = 6
    @AppStorage("trendsHiddenCSV") private var trendsHiddenCSV = ""
    @State private var showVisibility = false

    private var visibleMetrics: [Metric] {
        let hidden = Set(trendsHiddenCSV.split(separator: ",").map(String.init))
        return DashboardModel.placeholders.filter { !hidden.contains($0.id) }
    }

    private let rowHeight: CGFloat = 44
    private let colWidth: CGFloat = 92
    private let nameWidth: CGFloat = 122


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
        // Cell values come precomputed from the model (off the main thread);
        // the body only reads dictionaries.
        let ws = weeks
        let values = model.trendValues
        return NavigationStack {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    frozenColumn
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 0) {
                            ForEach(Array(ws.enumerated()), id: \.offset) { idx, week in
                                weekColumn(index: idx, week: week, weekCount: ws.count, values: values)
                            }
                            loadMoreColumn
                        }
                    }
                }
                .padding(.horizontal)

                summary(values: values)
                    .padding()

                ZoneSectionsView(mode: .history)
                    .padding(.bottom)
            }
            .navigationTitle(Text("Trends"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showVisibility = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showVisibility) {
                MetricVisibilityEditor(hiddenCSV: $trendsHiddenCSV)
            }
            .task(id: weeksOfHistory) { await loadHistory(force: false) }
            .onChange(of: weeksOfHistory) { _, _ in Task { await loadHistory(force: true) } }
            .refreshable { await loadHistory(force: true) }
            .overlay(alignment: .top) {
                if model.isLoadingHistory {
                    ProgressView().padding(.top, 6)
                }
            }
        }
    }

    /// Week-over-week summary: how many metrics improved vs declined this
    /// week, and the biggest movers in each direction.
    @ViewBuilder
    private func summary(values: [String: [Int: Double]]) -> some View {
        let changes: [(metric: Metric, better: Bool, pct: Double)] = visibleMetrics.compactMap { m in
            guard let cur = values[m.id]?[0], let prev = values[m.id]?[1], prev != 0, cur != prev else { return nil }
            let up = cur > prev
            let better = (DashboardModel.direction(for: m.id)) == up
            return (m, better, abs((cur - prev) / prev) * 100)
        }
        let improved = changes.filter { $0.better }.sorted { $0.pct > $1.pct }
        let declined = changes.filter { !$0.better }.sorted { $0.pct > $1.pct }

        VStack(alignment: .leading, spacing: 10) {
            Text("This Week vs Last").font(.headline)
            if changes.isEmpty {
                Text("Not enough data to compare yet.").font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    Label("\(improved.count) improved", systemImage: "arrow.up.circle.fill").foregroundStyle(.green)
                    Label("\(declined.count) declined", systemImage: "arrow.down.circle.fill").foregroundStyle(.red)
                }
                .font(.subheadline)
                if let top = improved.first {
                    Text("Biggest gain: \(String(localized: String.LocalizationValue(top.metric.titleKey))) (\(Int(top.pct))%)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let worst = declined.first {
                    Text("Needs attention: \(String(localized: String.LocalizationValue(worst.metric.titleKey))) (\(Int(worst.pct))%)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadHistory(force: Bool) async {
        let cacheOnly = !force && !DashboardModel.isStale()
        await model.loadHistory(context: context, garmin: session, oura: ouraSession,
                                renpho: renphoSession, weeks: weeksOfHistory, cacheOnly: cacheOnly)
        await model.refreshTrends(context: context, weeks: weeksOfHistory)
    }

    /// Trailing column that loads another block of older weeks on demand
    /// (older weeks are on the right, so the button lives at the end).
    private var loadMoreColumn: some View {
        VStack {
            if model.isLoadingHistory {
                ProgressView()
            } else {
                Button {
                    weeksOfHistory += 6
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                        Text("Load\n6 more").multilineTextAlignment(.center)
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(width: colWidth, height: rowHeight * 3)
        .padding(.top, rowHeight)
    }

    private var frozenColumn: some View {
        VStack(spacing: 0) {
            Text("Stat")
                .font(.caption.weight(.semibold))
                .frame(width: nameWidth, height: rowHeight, alignment: .leading)
            ForEach(visibleMetrics) { metric in
                NavigationLink { MetricDetailView(id: metric.id) } label: {
                    HStack(spacing: 3) {
                        Text(LocalizedStringKey(metric.titleKey))
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private func weekColumn(index: Int, week: (start: Date, end: Date), weekCount: Int,
                            values: [String: [Int: Double]]) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(index == 0 ? String(localized: "This wk") : header(week))
                    .font(.caption2.weight(.semibold))
                Text(week.start.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(width: colWidth, height: rowHeight)
            ForEach(visibleMetrics) { metric in
                NavigationLink { MetricDetailView(id: metric.id) } label: {
                    cellView(id: metric.id,
                             value: values[metric.id]?[index],
                             prev: index + 1 < weekCount ? values[metric.id]?[index + 1] : nil)
                        .frame(width: colWidth, height: rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
    private func cellView(id: String, value: Double?, prev: Double?) -> some View {
        HStack(spacing: 3) {
            Text(value.map { formatted(id: id, $0) } ?? "—")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(value == nil ? .secondary : .primary)
            if let value, let prev, value != prev {
                let up = value > prev
                let better = (DashboardModel.direction(for: id)) == up
                Image(systemName: up ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(better ? Color.green : Color.red)
            }
        }
    }

    private func formatted(id: String, _ value: Double) -> String {
        if let spec = DashboardModel.spec(for: id) { return spec.format(value) }
        return String(Int(value))   // activity metrics
    }
}
