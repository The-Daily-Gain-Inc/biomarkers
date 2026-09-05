import SwiftUI
import SwiftData

/// Launch sequence state. Everything the tabs need is loaded up front —
/// cloud merge, Garmin activities, dashboard metrics, trends history, HR-zone
/// bucketing — behind a blocking progress screen, so the first minute of use
/// isn't spent fighting background work for the main thread.
@MainActor
final class LaunchGate: ObservableObject {
    @Published var progress: Double = 0
    @Published var text: String = ""
    @Published var done = false
    @Published var canSkip = false
    let totalSteps = 7

    func step(_ index: Int, _ text: String) {
        progress = Double(index) / Double(totalSteps)
        self.text = text
    }
}

struct RootView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var ouraSession: OuraSession
    @EnvironmentObject var renphoSession: RenphoSession
    @EnvironmentObject var sync: SyncEngine
    @EnvironmentObject var zones: ZoneStore
    @EnvironmentObject var zoneAgg: ZoneAggregator
    @EnvironmentObject var cloud: CloudSync
    @EnvironmentObject var dashboard: DashboardModel
    @Environment(\.modelContext) private var context
    @StateObject private var gate = LaunchGate()
    @State private var showGarminLogin = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("backfillMonths") private var backfillMonths = 6
    @AppStorage("weeksOfHistory") private var weeksOfHistory = 6

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
        Group {
            if gate.done {
                tabs
            } else {
                LaunchLoadingView(gate: gate, detail: sync.progressText)
            }
        }
        .preferredColorScheme(colorScheme)
        .sheet(isPresented: $showGarminLogin) {
            GarminLoginSheet()
        }
        .task { await preload() }
        .onChange(of: scenePhase) { _, phase in
            // Pull-on-foreground so multiple devices converge. Always a MERGE
            // (keyed by stable id, timestamp-arbitrated) — never delete-all.
            guard phase == .active, gate.done, cloud.didRestore else { return }
            Task {
                await cloud.restore(context: context, incremental: true)
                await cloud.backup(context: context)
            }
        }
    }

    private var tabs: some View {
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
        .onAppear {
            // -SkipAutoLogin YES lets simulator UI checks bypass the sheet.
            if !session.isLoggedIn && !UserDefaults.standard.bool(forKey: "SkipAutoLogin") {
                showGarminLogin = true
            }
        }
    }

    /// The whole launch pipeline, in order, with the progress bar advancing
    /// per stage. Network stages are skipped when the cache is fresh, so a
    /// warm launch takes a second or two.
    private func preload() async {
        guard !gate.done else { return }
        // Never let a hung network call brick the app: after 25 s the user
        // can continue into the tabs while the rest finishes in the background.
        let skipTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if !gate.done { gate.canSkip = true }
        }
        defer { skipTimer.cancel() }

        gate.step(0, String(localized: "Signing in…"))
        await cloud.signIn()

        gate.step(1, String(localized: "Merging cloud data…"))
        await cloud.restore(context: context, incremental: true)
        await cloud.seed(context: context)

        let stale = DashboardModel.isStale()
        if session.isLoggedIn && stale {
            gate.step(2, String(localized: "Syncing Garmin activities…"))
            await sync.sync(context: context, session: session, backfillMonths: backfillMonths)
        }

        gate.step(3, String(localized: "Loading today's biomarkers…"))
        await dashboard.load(context: context, garmin: session, oura: ouraSession,
                             renpho: renphoSession, cacheOnly: !stale)

        gate.step(4, String(localized: "Loading trends…"))
        await dashboard.loadHistory(context: context, garmin: session, oura: ouraSession,
                                    renpho: renphoSession, weeks: weeksOfHistory, cacheOnly: !stale)
        await dashboard.refreshTrends(context: context, weeks: weeksOfHistory, force: true)

        gate.step(5, String(localized: "Crunching heart-rate zones…"))
        let acts = (try? context.fetch(FetchDescriptor<CachedActivity>(sortBy: [SortDescriptor(\.startDate, order: .reverse)]))) ?? []
        await zoneAgg.rebuild(signature: ZoneAggregator.signature(activities: acts, maxHR: zones.maxHR),
                              activities: acts, floors: zones.floors)

        gate.step(6, String(localized: "Almost there…"))
        gate.step(7, String(localized: "Ready"))
        gate.done = true

        // Backup goes up after the UI is usable — it's the one stage that
        // doesn't need to finish before you can read your numbers.
        Task { await cloud.backup(context: context, isLaunch: true) }
    }
}

/// Full-screen launch progress. Blocks interaction until the gate opens.
struct LaunchLoadingView: View {
    @ObservedObject var gate: LaunchGate
    var detail: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Biomarkers")
                .font(.title2.weight(.semibold))
            ProgressView(value: gate.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
                .animation(.easeInOut(duration: 0.25), value: gate.progress)
            Text(gate.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            if gate.canSkip {
                Button("Continue anyway") { gate.done = true }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
