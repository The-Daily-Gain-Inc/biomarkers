import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: SessionStore
    @State private var showGarminLogin = false

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
            WeeklyZonesView()
                .tabItem { Label("HR Zones", systemImage: "heart.text.square") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showGarminLogin) {
            GarminLoginSheet()
        }
        .onChange(of: session.needsLogin) { _, needs in
            if needs { showGarminLogin = true }
        }
        .onAppear {
            // -SkipAutoLogin YES lets simulator UI checks bypass the sheet.
            if !session.isLoggedIn && !UserDefaults.standard.bool(forKey: "SkipAutoLogin") {
                showGarminLogin = true
            }
        }
    }
}
