import Foundation

/// Hands today's headline values to the home-screen widget. Called every
/// time the dashboard re-renders from cache. Unlike the 7-day dashboard
/// tiles (averages), the widget shows the value for *today* only.
@MainActor
enum WidgetPublisher {
    static func publish(rows: [DailyMetric]) {
        let cal = Calendar.current
        var grouped: [String: [Date: Double]] = [:]
        for r in rows where WidgetBridge.headlineIds.contains(r.metricKey) {
            grouped[r.metricKey, default: [:]][cal.startOfDay(for: r.day)] = r.value
        }
        let picked = WidgetBridge.headlineIds.compactMap { WidgetBridge.metric(id: $0, byDay: grouped[$0] ?? [:]) }
        WidgetBridge.save(WidgetSnapshot(metrics: picked, updatedAt: Date()))
    }
}
