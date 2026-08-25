import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var ouraSession: OuraSession
    @EnvironmentObject var sync: SyncEngine
    @Environment(\.modelContext) private var context
    @AppStorage("backfillMonths") private var backfillMonths = 6
    @State private var showGarminLogin = false
    @State private var showOuraLogin = false
    @State private var ouraTokenInput = ""
    @State private var cachedCount = 0
    @ObservedObject private var log = DebugLog.shared

    var body: some View {
        NavigationStack {
            Form {
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
