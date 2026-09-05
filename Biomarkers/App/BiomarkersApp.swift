import SwiftUI
import SwiftData
import FirebaseCore

@main
struct BiomarkersApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var ouraSession = OuraSession()
    @StateObject private var renphoSession = RenphoSession()
    @StateObject private var sync = SyncEngine()
    @StateObject private var zones = ZoneStore()
    @StateObject private var zoneAgg = ZoneAggregator()
    @StateObject private var cloud = CloudSync()
    /// One model for Dashboard and Trends — each tab used to own a copy and
    /// each copy loaded the full metric table.
    @StateObject private var dashboard = DashboardModel()

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(ouraSession)
                .environmentObject(renphoSession)
                .environmentObject(sync)
                .environmentObject(zones)
                .environmentObject(zoneAgg)
                .environmentObject(cloud)
                .environmentObject(dashboard)
        }
        .modelContainer(for: [
            CachedActivity.self, DailyMetric.self,
            RetroRow.self, RetroColumn.self, RetroCell.self, RetroDream.self, LongevityRule.self,
            WorkoutBlock.self,
        ])
    }
}
