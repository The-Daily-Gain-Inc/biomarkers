import SwiftUI
import SwiftData

@main
struct BiomarkersApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var ouraSession = OuraSession()
    @StateObject private var sync = SyncEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(ouraSession)
                .environmentObject(sync)
        }
        .modelContainer(for: CachedActivity.self)
    }
}
