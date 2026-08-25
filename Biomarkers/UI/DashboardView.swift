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
                ProfileCard()
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.metrics.filter { $0.value != nil }) { metric in
                        MetricTile(metric: metric)
                    }
                }
                .padding(.horizontal)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text("Last 7 Days"))
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

/// Read-only personal reference stats, shown at the top of the dashboard.
struct ProfileCard: View {
    private let items: [(String, String)] = [
        ("Age", "\(ProfileConstants.age)"),
        ("Height", "\(ProfileConstants.heightCm) cm"),
        ("Weight", String(format: "%.1f lb", ProfileConstants.weightLbs)),
        ("Min protein", String(format: "%.0f g", ProfileConstants.minProteinG)),
        ("Target protein", String(format: "%.0f g", ProfileConstants.targetProteinG)),
        ("Baseline kcal", "\(ProfileConstants.baselineCalories)"),
    ]
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
