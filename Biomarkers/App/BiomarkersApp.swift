import SwiftUI
import SwiftData

@main
struct BiomarkersApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var ouraSession = OuraSession()
    @StateObject private var sync = SyncEngine()
    @StateObject private var zones = ZoneStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(ouraSession)
                .environmentObject(sync)
                .environmentObject(zones)
        }
        .modelContainer(for: [CachedActivity.self, DailyMetric.self])
    }
}
