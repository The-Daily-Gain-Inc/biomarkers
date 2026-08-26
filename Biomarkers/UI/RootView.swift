import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.modelContext) private var context
    @State private var showGarminLogin = false
    @AppStorage("appearance") private var appearance = "system"

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
    // -InitialTab 0|1|2 lets simulator UI checks land on a specific tab.
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "InitialTab")

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
                .tag(0)
            TrendsView()
                .tabItem { Label("Trends", systemImage: "tablecells") }
                .tag(1)
            WeeklyZonesView()
                .tabItem { Label("Zones", systemImage: "heart.text.square") }
                .tag(2)
            LifeView()
                .tabItem { Label("Life", systemImage: "target") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
        .preferredColorScheme(colorScheme)
        .sheet(isPresented: $showGarminLogin) {
            GarminLoginSheet()
        }
        .onAppear {
            // -SkipAutoLogin YES lets simulator UI checks bypass the sheet.
            if !session.isLoggedIn && !UserDefaults.standard.bool(forKey: "SkipAutoLogin") {
                showGarminLogin = true
            }
        }
        .task {
            // Merge any cloud data into the local store, one-time seed the
            // bundled biomarker history, then back up.
            await cloud.signIn()
            await cloud.restore(context: context)
            _ = BiomarkerSeeder.seedIfNeeded(context: context)
            await cloud.backup(context: context)
        }
    }
}
