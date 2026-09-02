import WidgetKit
import SwiftUI

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let isEmpty: Bool
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: Date(), snapshot: .placeholder, isEmpty: false) }
    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? TodayEntry(date: Date(), snapshot: .placeholder, isEmpty: false) : current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        // The app reloads us after every dashboard refresh; poll every few
        // hours anyway so a stale snapshot can't sit all day.
        let next = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date()
        completion(Timeline(entries: [current()], policy: .after(next)))
    }
    private func current() -> TodayEntry {
        if let s = WidgetBridge.load(), !s.metrics.isEmpty { return TodayEntry(date: Date(), snapshot: s, isEmpty: false) }
        return TodayEntry(date: Date(), snapshot: WidgetSnapshot(metrics: [], updatedAt: .distantPast), isEmpty: true)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Seven-day sparkline; last point emphasized.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let n = values.count
            if n >= 2, let lo = values.min(), let hi = values.max() {
                let span = max(hi - lo, 0.0001)
                let pts = values.enumerated().map { i, v in
                    CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(n - 1),
                            y: geo.size.height * (1 - CGFloat((v - lo) / span)) )
                }
                Path { p in p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) } }
                    .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                Circle().fill(color).frame(width: 4, height: 4).position(pts[n - 1])
            }
        }
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    private var shown: [WidgetMetric] {
        Array(entry.snapshot.metrics.prefix(family == .systemSmall ? 2 : (family == .systemLarge ? 6 : 4)))
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: grid
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Today", systemImage: "waveform.path.ecg")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !entry.isEmpty {
                    Text(entry.snapshot.updatedAt, style: .relative)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if entry.isEmpty {
                Spacer()
                Text("Open Biomarkers to load today's numbers")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                let cols = family == .systemSmall ? 1 : 2
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 6) {
                    ForEach(shown) { m in cell(m) }
                }
            }
        }
    }

    private func cell(_ m: WidgetMetric) -> some View {
        let tint = Color(hex: m.tint)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(m.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(m.value).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(tint)
                        .minimumScaleFactor(0.7).lineLimit(1)
                    if let u = m.unit { Text(u).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 2)
            Sparkline(values: m.series, color: tint).frame(width: 44, height: 22)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let m = entry.snapshot.metrics.first {
                VStack(spacing: 0) {
                    Text(m.title.prefix(5)).font(.system(size: 9)).lineLimit(1)
                    Text(m.value).font(.system(size: 16, weight: .bold, design: .rounded))
                }
            } else { Image(systemName: "waveform.path.ecg") }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entry.snapshot.metrics.prefix(3)) { m in
                HStack {
                    Text(m.title).font(.caption2)
                    Spacer()
                    Text(m.value + (m.unit.map { " \($0)" } ?? "")).font(.caption.weight(.semibold))
                }
            }
            if entry.isEmpty { Text("Open Biomarkers").font(.caption2) }
        }
    }

    private var inline: some View {
        Text(entry.snapshot.metrics.prefix(2).map { "\($0.title) \($0.value)" }.joined(separator: " · "))
    }
}

struct BiomarkersTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBridge.widgetKind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Readiness, sleep, HRV and resting heart rate with a week of trend.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct BiomarkersWidgetBundle: WidgetBundle {
    var body: some Widget { BiomarkersTodayWidget() }
}
