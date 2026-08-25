import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var ouraSession: OuraSession
    @EnvironmentObject var renphoSession: RenphoSession
    @EnvironmentObject var sync: SyncEngine
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
                TodayCard()
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 4)

                if mode == .today {
                    TodayCard()
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                    ProfileCard()
                        .padding(.horizontal)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.metrics.filter { $0.value != nil }) { metric in
                            MetricTile(metric: metric)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text("Biomarkers"))
            .sheet(isPresented: $showGarminLogin) { GarminLoginSheet() }
            .refreshable { await reload() }
            .task { await reload() }
            .onChange(of: session.token) { _, token in
                if token != nil { Task { await reload() } }
            }
            .onChange(of: ouraSession.token) { _, token in
                if token != nil { Task { await reload() } }
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

    private func reload() async {
        if session.isLoggedIn {
            await sync.sync(context: context, session: session, backfillMonths: backfillMonths)
        }
        await model.load(context: context, garmin: session, oura: ouraSession, renpho: renphoSession)
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
    @AppStorage("lastUpdate.oura") private var ouraTS: Double = 0
    @AppStorage("lastUpdate.garmin") private var garminTS: Double = 0
    @AppStorage("lastUpdate.renpho") private var renphoTS: Double = 0

    private func latest(_ key: String) -> Double? { all.first { $0.metricKey == key }?.value }
    private func score(_ key: String) -> String? { latest(key).map { "\(Int($0.rounded()))" } }

    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: cols, spacing: 14) {
                stat("Readiness", score("readiness"), nil)
                stat("Sleep", score("sleep_score"), nil)
                stat("Stress", score("stress"), nil)
                stat("Activity", score("o_activity"), nil)
                stat("HRV", score("o_hrv"), "ms")
                stat("Resting HR", score("rhr"), "bpm")
            }
            Divider()
            HStack(spacing: 14) {
                updated("Oura", ouraTS)
                updated("Garmin", garminTS)
                updated("Renpho", renphoTS)
            }
            .font(.caption2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func stat(_ title: String, _ value: String?, _ unit: String?) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "—").font(.system(.title2, design: .rounded, weight: .semibold))
                if let unit, value != nil { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(LocalizedStringKey(title)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func updated(_ name: String, _ ts: Double) -> some View {
        VStack(spacing: 1) {
            Text(name).foregroundStyle(.secondary)
            Text(ts > 0 ? relative(ts) : "—")
                .foregroundStyle(ts > 0 ? .primary : .tertiary)
        }
        .frame(maxWidth: .infinity)
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

    /// Renpho stores kg; guard in case a value already arrives in lb.
    private var weightLb: Double {
        guard let v = weights.first?.value else { return ProfileConstants.weightLbs }
        return v < 120 ? v * 2.20462 : v
    }
    private var minProtein: Double { weightLb * 0.55 }
    private var targetProtein: Double { minProtein + 40 }

    private var items: [(String, String)] {
        [
            ("Age", "\(ProfileConstants.age)"),
            ("Height", "\(ProfileConstants.heightCm) cm"),
            ("Weight", String(format: "%.1f lb", weightLb)),
            ("Min protein", String(format: "%.0f g", minProtein)),
            ("Target protein", String(format: "%.0f g", targetProtein)),
            ("Baseline kcal", "\(ProfileConstants.baselineCalories)"),
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
