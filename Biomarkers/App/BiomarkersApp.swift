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
    @StateObject private var cloud = CloudSync()

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
                .environmentObject(cloud)
        }
        .modelContainer(for: [
            CachedActivity.self, DailyMetric.self,
            RetroRow.self, RetroColumn.self, RetroCell.self, RetroDream.self, LongevityRule.self,
            WorkoutBlock.self,
        ])
    }
}
