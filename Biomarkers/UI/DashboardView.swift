import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var ouraSession: OuraSession
    @EnvironmentObject var renphoSession: RenphoSession
    @EnvironmentObject var sync: SyncEngine
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.modelContext) private var context
    @StateObject private var model = DashboardModel()
    @AppStorage("backfillMonths") private var backfillMonths = 6
    @State private var showGarminLogin = false
    @State private var showLog = false
    @State private var mode: Mode = .today
    enum Mode: String, CaseIterable { case today = "Today", week = "Last 7 Days" }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if !session.isLoggedIn {
                    ConnectBanner(text: "Garmin not connected") { showGarminLogin = true }
                } else if session.needsLogin {
                    ConnectBanner(text: "Garmin session expired") { showGarminLogin = true }
                }
                if !ouraSession.isConnected {
                    ConnectBanner(text: "Oura not connected — connect in Settings", action: nil)
                }
                if let error = sync.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                if let progress = sync.progressText {
                    Text(progress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)

                AppShortcuts()
                    .padding(.horizontal)
                    .padding(.bottom, 10)

                if mode == .today {
                    TodayCard()
                        .padding(.horizontal)
                        .padding(.bottom, 10)
                    ProfileCard()
                        .padding(.horizontal)
                } else {
                    weekGrid
                }
            }
            .swipeSegments($mode)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text("Biomarkers"))
            .sheet(isPresented: $showGarminLogin) { GarminLoginSheet() }
            .refreshable { await reload(force: true) }
            .task { await reload() }
            .onChange(of: session.token) { _, token in
                if token != nil { Task { await reload(force: true) } }
            }
            .onChange(of: ouraSession.token) { _, token in
                if token != nil { Task { await reload(force: true) } }
            }
            .onChange(of: cloud.bootstrapDone) { _, done in
                if done { Task { await reload(force: true) } }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLog = true } label: { Label("Log", systemImage: "square.and.pencil") }
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.isLoading || sync.isSyncing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await reload() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .sheet(isPresented: $showLog, onDismiss: { Task { await reload() } }) {
                LogEntryView()
            }
        }
    }

    /// The "Last 7 Days" grid, organized into a section per provider so it
    /// reads as a structured report rather than an undifferentiated wall.
    private var weekGrid: some View {
        let visible = model.metrics.filter { $0.value != nil }
        let order: [Metric.Provider] = [.garmin, .oura, .renpho, .manual]
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(order, id: \.self) { provider in
                let group = visible.filter { $0.provider == provider }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(provider.rawValue.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(group) { metric in
                                NavigationLink { MetricDetailView(id: metric.id) } label: { MetricTile(metric: metric) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func reload(force: Bool = false) async {
        let cacheOnly = !force && !DashboardModel.isStale()
        if !cacheOnly && session.isLoggedIn {
            await sync.sync(context: context, session: session, backfillMonths: backfillMonths)
        }
        await model.load(context: context, garmin: session, oura: ouraSession, renpho: renphoSession, cacheOnly: cacheOnly)
        if !cacheOnly { cloud.requestBackup(context: context) }
    }
}

struct ConnectBanner: View {
    let text: String
    let action: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle")
            Text(LocalizedStringKey(text))
                .font(.footnote)
            Spacer()
            if let action {
                Button("Sign In", action: action)
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
}

/// The default "Today" view: headline scores for the day plus how recently
/// each provider synced.
struct TodayCard: View {
    @Query(sort: \DailyMetric.day, order: .reverse) private var all: [DailyMetric]
    @Query(sort: \CachedActivity.startDate, order: .reverse) private var activities: [CachedActivity]
    @AppStorage("lastUpdate.oura") private var ouraTS: Double = 0
    @AppStorage("lastUpdate.garmin") private var garminTS: Double = 0
    @AppStorage("lastUpdate.renpho") private var renphoTS: Double = 0
    @AppStorage("battery.garmin") private var garminBattery: Int = -1

    private func latest(_ key: String) -> Double? { all.first { $0.metricKey == key }?.value }
    private func score(_ key: String) -> String? { latest(key).map { "\(Int($0.rounded()))" } }

    /// Whether a workout was performed today (and how many).
    private var workoutToday: String {
        let count = activities.filter { Calendar.current.isDateInToday($0.startDate) }.count
        return count > 0 ? "\(count)" : "No"
    }

    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private struct Item { let id: String; let title: String; let value: String?; let unit: String?; let tint: Color }

    private var items: [Item] {
        [
            Item(id: "readiness", title: "Readiness", value: score("readiness"), unit: nil, tint: Color(hex: 0x2FA36B)),
            Item(id: "sleep_score", title: "Sleep", value: score("sleep_score"), unit: nil, tint: Color(hex: 0x5B6CF0)),
            Item(id: "o_stress", title: "Stress", value: latest("o_stress").map { String(format: "%.1f", $0) }, unit: "h", tint: Color(hex: 0xE0791F)),
            Item(id: "gym", title: "Workout", value: workoutToday, unit: nil, tint: Color(hex: 0x00A6A0)),
            Item(id: "steps", title: "Steps", value: score("steps"), unit: nil, tint: Color(hex: 0x2E8BE6)),
            Item(id: "o_hrv", title: "HRV", value: score("o_hrv"), unit: "ms", tint: Color(hex: 0x8A6BD6)),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(items, id: \.id) { item in
                    NavigationLink { MetricDetailView(id: item.id) } label: { cell(item) }
                        .buttonStyle(.plain)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Last synced").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    updated("Oura", ouraTS, Color(hex: 0x6C5CE7), nil)
                    updated("Garmin", garminTS, Color(hex: 0x007CC3), garminBattery >= 0 ? garminBattery : nil)
                    updated("Renpho", renphoTS, Color(hex: 0x00B3A4), nil)
                }
                .font(.caption2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func cell(_ item: Item) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(item.value ?? "—")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(item.value == nil ? Color.secondary : item.tint)
                if let unit = item.unit, item.value != nil {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(LocalizedStringKey(item.title)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(item.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func updated(_ name: String, _ ts: Double, _ color: Color, _ battery: Int?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(ts > 0 ? color : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).foregroundStyle(.secondary)
                Text(ts > 0 ? relative(ts) : "—").foregroundStyle(ts > 0 ? .primary : .tertiary)
                if let battery {
                    HStack(spacing: 2) {
                        Image(systemName: batterySymbol(battery))
                        Text("\(battery)%")
                    }
                    .foregroundStyle(battery <= 20 ? .red : .secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func relative(_ ts: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
}

/// Personal reference stats. Weight and protein targets are derived from the
/// latest cached Renpho weight; min protein = weight(lb) × 0.55, target = +40.
struct ProfileCard: View {
    @Query(filter: #Predicate<DailyMetric> { $0.metricKey == "rp_weight" },
           sort: \DailyMetric.day, order: .reverse)
    private var weights: [DailyMetric]
    @AppStorage("profile.dob") private var dobTS = 0.0
    @AppStorage("profile.heightCm") private var heightCm = 0
    @AppStorage("profile.baselineKcal") private var baselineKcal = 0

    private var age: Int? {
        guard dobTS > 0 else { return nil }
        return Calendar.current.dateComponents([.year], from: Date(timeIntervalSince1970: dobTS), to: Date()).year
    }

    /// Latest weight in lb (Renpho stores kg), or nil if none recorded.
    private var weightLb: Double? {
        guard let v = weights.first?.value else { return nil }
        return v < 120 ? v * 2.20462 : v
    }

    private var items: [(String, String)] {
        let w = weightLb
        let minP = w.map { $0 * 0.55 }
        return [
            ("Age", age.map { "\($0)" } ?? "—"),
            ("Height", heightCm > 0 ? "\(heightCm) cm" : "—"),
            ("Weight", w.map { String(format: "%.1f lb", $0) } ?? "—"),
            ("Min protein", minP.map { String(format: "%.0f g", $0) } ?? "—"),
            ("Target protein", minP.map { String(format: "%.0f g", $0 + 40) } ?? "—"),
            ("Baseline kcal", baselineKcal > 0 ? "\(baselineKcal)" : "—"),
        ]
    }
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(items, id: \.0) { item in
                VStack(spacing: 2) {
                    Text(item.1).font(.system(.callout, design: .rounded, weight: .semibold))
                    Text(LocalizedStringKey(item.0)).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct MetricTile: View {
    let metric: Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(metric.titleKey))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(metric.provider.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(metric.value ?? "—")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .contentTransition(.numericText())
                if let unit = metric.unit, metric.value != nil {
                    Text(LocalizedStringKey(unit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if metric.series.count >= 2 {
                Chart(Array(metric.series.enumerated()), id: \.offset) { item in
                    LineMark(
                        x: .value("Day", item.offset),
                        y: .value("Value", item.element)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: sparkDomain)
                .foregroundStyle(.tint)
                .frame(height: 24)
            } else {
                Spacer().frame(height: 24)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var sparkDomain: ClosedRange<Double> {
        let lo = metric.series.min() ?? 0
        let hi = metric.series.max() ?? 1
        let pad = max((hi - lo) * 0.15, 0.5)
        return (lo - pad)...(hi + pad)
    }
}
