import SwiftUI

/// Hands the dashboard's headline metrics to the home-screen widget.
/// Called every time the dashboard re-renders from cache.
@MainActor
enum WidgetPublisher {
    static func publish(from metrics: [Metric]) {
        let picked: [WidgetMetric] = WidgetBridge.headlineIds.compactMap { id in
            guard let m = metrics.first(where: { $0.id == id }), let value = m.value else { return nil }
            return WidgetMetric(id: id,
                                title: m.titleKey,
                                value: value,
                                unit: m.unit,
                                series: Array(m.series.suffix(7)),
                                tint: DashboardModel.tintHex(for: id),
                                higherIsBetter: DashboardModel.higherIsBetter[id] ?? true)
        }
        WidgetBridge.save(WidgetSnapshot(metrics: picked, updatedAt: Date()))
    }
}
