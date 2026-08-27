import SwiftUI
import SwiftData
import AuthenticationServices

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var ouraSession: OuraSession
    @EnvironmentObject var renphoSession: RenphoSession
    @EnvironmentObject var cloud: CloudSync
    @EnvironmentObject var sync: SyncEngine
    @Environment(\.modelContext) private var context
    @AppStorage("backfillMonths") private var backfillMonths = 6
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("profile.dob") private var profileDobTS = 0.0
    @AppStorage("profile.heightCm") private var profileHeight = 0
    @AppStorage("profile.baselineKcal") private var profileKcal = 0

    private var dobBinding: Binding<Date> {
        Binding(
            get: { profileDobTS > 0 ? Date(timeIntervalSince1970: profileDobTS)
                    : Calendar.current.date(byAdding: .year, value: -30, to: Date())! },
            set: { profileDobTS = $0.timeIntervalSince1970 }
        )
    }
    private var age: Int? {
        guard profileDobTS > 0 else { return nil }
        return Calendar.current.dateComponents([.year], from: Date(timeIntervalSince1970: profileDobTS), to: Date()).year
    }
    @State private var showGarminLogin = false
    @State private var showOuraLogin = false
    @State private var ouraTokenInput = ""
    @State private var renphoEmail = ""
    @State private var renphoPassword = ""
    @State private var renphoBusy = false
    @State private var cachedCount = 0
    @EnvironmentObject private var zones: ZoneStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var log = DebugLog.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Label("Cloud", systemImage: cloud.isSignedIn ? "checkmark.icloud.fill" : "icloud")
                            .foregroundStyle(cloud.isSignedIn ? .green : .secondary)
                        Spacer()
                        if cloud.isSyncing { ProgressView() }
                        else if let last = cloud.lastBackup {
                            Text(last.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Back Up Now") {
                        Task { await cloud.backup(context: context) }
                    }
                    .disabled(cloud.isSyncing)
                    Button("Restore from Cloud") {
                        Task { await cloud.restore(context: context) }
                    }
                    .disabled(cloud.isSyncing)
                    if cloud.isAnonymous {
                        SignInWithAppleButton(.signIn) { request in
                            cloud.prepareAppleRequest(request)
                        } onCompletion: { result in
                            Task { await cloud.completeAppleSignIn(result, context: context) }
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 44)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    } else {
                        Label("Signed in with Apple", systemImage: "applelogo")
                            .foregroundStyle(.secondary)
                        Button("Sign Out", role: .destructive) {
                            Task { await cloud.signOut() }
                        }
                    }
                    if let error = cloud.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Cloud Backup")
                } footer: {
                    Text("Everything is mirrored to Firestore and restored on a fresh install. Sign in with Apple to keep the same account across devices.")
                }

                Section {
                    NavigationLink {
                        CustomBiomarkersView()
                    } label: {
                        Label("Custom Biomarkers", systemImage: "plus.circle")
                    }
                    NavigationLink {
                        DataExplorerView()
                    } label: {
                        Label("All Metrics (raw)", systemImage: "list.bullet.rectangle")
                    }
                } footer: {
                    Text("Add your own biomarkers, or browse every field Garmin and Oura relay for the latest day.")
                }
                Section("Profile") {
                    DatePicker("Date of Birth", selection: dobBinding,
                               in: ...Date(), displayedComponents: .date)
                    Stepper(value: $profileHeight, in: 0...250, step: 1) {
                        LabeledContent("Height") { Text(profileHeight > 0 ? "\(profileHeight) cm" : "—").foregroundStyle(.secondary) }
                    }
                    if let age { LabeledContent("Age") { Text("\(age)").foregroundStyle(.secondary) } }
                    Stepper(value: $profileKcal, in: 0...6000, step: 50) {
                        LabeledContent("Baseline kcal") { Text(profileKcal > 0 ? "\(profileKcal)" : "—").foregroundStyle(.secondary) }
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section {
                    if session.isLoggedIn {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Sign Out", role: .destructive) { session.logout() }
                    } else {
                        Button("Sign In to Garmin") { showGarminLogin = true }
                    }
                    Picker(selection: $backfillMonths) {
                        Text("1 month").tag(1)
                        Text("3 months").tag(3)
                        Text("6 months").tag(6)
                        Text("1 year").tag(12)
                        Text("2 years").tag(24)
                        Text("All time").tag(0)
                    } label: {
                        Text("Backfill")
                    }
                    Button {
                        Task { await sync.sync(context: context, session: session, backfillMonths: backfillMonths) }
                    } label: {
                        if sync.isSyncing {
                            HStack {
                                ProgressView()
                                Text(sync.progressText ?? String(localized: "Syncing…"))
                            }
                        } else {
                            Text("Sync Now")
                        }
                    }
                    .disabled(!session.isLoggedIn || sync.isSyncing)
                    if let error = sync.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    LabeledContent {
                        Text("\(cachedCount)")
                    } label: {
                        Text("Cached activities")
                    }
                } header: {
                    Text("Garmin")
                } footer: {
                    Text("Uses your Garmin Connect web session. Activities are cached locally, so history survives even if Garmin changes their endpoints.")
                }

                Section {
                    if ouraSession.isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Disconnect", role: .destructive) { ouraSession.disconnect() }
                    } else {
                        Button("Connect with Oura") { showOuraLogin = true }
                        SecureField(String(localized: "Or paste a personal access token"), text: $ouraTokenInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save Token") {
                            ouraSession.setPersonalToken(ouraTokenInput)
                            ouraTokenInput = ""
                        }
                        .disabled(ouraTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let error = ouraSession.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Oura")
                } footer: {
                    Text("Signs in via Oura OAuth (redirect to thedailygain.ca is intercepted in-app). Personal tokens can be created at cloud.ouraring.com.")
                }

                Section {
                    if renphoSession.isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let email = renphoSession.creds?.email {
                            Text(email).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Disconnect", role: .destructive) { renphoSession.disconnect() }
                    } else {
                        TextField(String(localized: "Renpho email"), text: $renphoEmail)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                        SecureField(String(localized: "Renpho password"), text: $renphoPassword)
                        Button {
                            renphoBusy = true
                            Task {
                                await renphoSession.login(email: renphoEmail, password: renphoPassword)
                                renphoBusy = false
                                if renphoSession.isConnected { renphoPassword = "" }
                            }
                        } label: {
                            if renphoBusy {
                                HStack { ProgressView(); Text("Signing in…") }
                            } else {
                                Text("Connect Renpho")
                            }
                        }
                        .disabled(renphoBusy || renphoEmail.isEmpty || renphoPassword.isEmpty)
                    }
                    if let error = renphoSession.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Renpho")
                } footer: {
                    Text("Uses your Renpho account to pull body composition (body fat, muscle, water, visceral fat, BMI, BMR, bone mass). Credentials are stored only in the device Keychain.")
                }

                Section {
                    HStack {
                        Text("Max HR")
                        Spacer()
                        TextField("bpm", value: Binding(
                            get: { zones.maxHR },
                            set: { zones.maxHR = max(120, min(230, $0)) }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        Text("bpm").foregroundStyle(.secondary)
                    }
                    ForEach(1...5, id: \.self) { zone in
                        HStack {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(ZonePalette.color(zone: zone, scheme: colorScheme))
                                .frame(width: 14, height: 14)
                            Text("Zone \(zone)")
                            Spacer()
                            Text("\(Int(ZoneStore.zonePercents[zone - 1] * 100))% · \(zones.rangeLabel(zone: zone)) bpm")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        Task { await zones.resetToGarmin(session: session) }
                    } label: {
                        if zones.isFetchingDefaults {
                            HStack { ProgressView(); Text("Fetching from Garmin…") }
                        } else {
                            Text("Estimate Max HR from Garmin")
                        }
                    }
                    .disabled(!session.isLoggedIn || zones.isFetchingDefaults)
                } header: {
                    Text("Heart Rate Zones")
                } footer: {
                    Text("Set your Max HR — the five zones adjust on their own as %HRmax (50/60/70/80/90%). Zone breakdowns are recomputed from each activity's heart-rate trace against these bounds.")
                }

                Section {
                    if log.lines.isEmpty {
                        Text("No entries yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(log.lines.suffix(25).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Button("Copy All") {
                            UIPasteboard.general.string = log.joined
                        }
                    }
                } header: {
                    Text("Diagnostics")
                }

                Section {
                    Button("Delete Cache", role: .destructive) {
                        try? context.delete(model: CachedActivity.self)
                        try? context.save()
                        updateCount()
                    }
                } footer: {
                    Text("Removes all locally cached activities. The next sync re-downloads the full backfill window.")
                }
            }
            .navigationTitle(Text("Settings"))
            .sheet(isPresented: $showGarminLogin) { GarminLoginSheet() }
            .sheet(isPresented: $showOuraLogin) { OuraLoginSheet() }
            .onAppear(perform: updateCount)
        }
    }

    private func updateCount() {
        cachedCount = (try? context.fetchCount(FetchDescriptor<CachedActivity>())) ?? 0
    }
}
