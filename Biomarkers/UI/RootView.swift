import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.modelContext) private var context
    @State private var showGarminLogin = false
    @Environment(\.scenePhase) private var scenePhase
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
            NavigationStack { RetroMatrix() }
                .tabItem { Label("Retro", systemImage: "square.and.pencil") }
                .tag(2)
            LifeView()
                .tabItem { Label("Life", systemImage: "target") }
                .tag(4)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(5)
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
            // Merge cloud data, seed only what the account is missing, back up.
            await cloud.signIn()
            await cloud.restore(context: context)
            await cloud.seed(context: context)
            await cloud.backup(context: context, isLaunch: true)
        }
        .onChange(of: scenePhase) { _, phase in
            // Pull-on-foreground so multiple devices converge. Always a MERGE
            // (keyed by stable id, timestamp-arbitrated) — never delete-all.
            guard phase == .active, cloud.didRestore else { return }
            Task {
                await cloud.restore(context: context, incremental: true)
                await cloud.backup(context: context)
            }
        }
    }
}
