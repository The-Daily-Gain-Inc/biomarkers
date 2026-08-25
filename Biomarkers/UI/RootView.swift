import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: SessionStore
    @State private var showGarminLogin = false
    // -InitialTab 0|1|2 lets simulator UI checks land on a specific tab.
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "InitialTab")

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
                .tag(0)
            WeeklyZonesView()
                .tabItem { Label("HR Zones", systemImage: "heart.text.square") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .sheet(isPresented: $showGarminLogin) {
            GarminLoginSheet()
        }
        .onAppear {
            // -SkipAutoLogin YES lets simulator UI checks bypass the sheet.
            if !session.isLoggedIn && !UserDefaults.standard.bool(forKey: "SkipAutoLogin") {
                showGarminLogin = true
            }
        }
    }
}
