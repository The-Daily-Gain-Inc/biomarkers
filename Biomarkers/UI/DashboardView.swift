import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var ouraSession: OuraSession
    @EnvironmentObject var sync: SyncEngine
    @Environment(\.modelContext) private var context
    @StateObject private var model = DashboardModel()
    @AppStorage("backfillMonths") private var backfillMonths = 6

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let progress = sync.progressText {
                    Text(progress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.metrics) { metric in
                        MetricTile(metric: metric)
                    }
                }
                .padding(.horizontal)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text("Last 7 Days"))
            .refreshable { await reload() }
            .task { await reload() }
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
        await model.load(context: context, garmin: session, oura: ouraSession)
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
