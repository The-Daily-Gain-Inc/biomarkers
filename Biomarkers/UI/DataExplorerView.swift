import SwiftUI

/// Read-only browser of every field Garmin and Oura relay for the most recent
/// day — the full raw payloads, searchable. Hidden away in Settings; useful
/// for discovering metrics not surfaced elsewhere.
struct DataExplorerView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var ouraSession: OuraSession

    @State private var sections: [Section] = []
    @State private var loading = false
    @State private var query = ""

    struct Section: Identifiable {
        let id = UUID()
        let title: String
        let rows: [(key: String, value: String)]
    }

    var body: some View {
        List {
            if loading && sections.isEmpty {
                HStack { ProgressView(); Text("Loading raw data…").foregroundStyle(.secondary) }
            }
            ForEach(filtered) { section in
                SwiftUI.Section(section.title) {
                    ForEach(section.rows, id: \.key) { row in
                        HStack(alignment: .top) {
                            Text(row.key).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.value).font(.system(.caption, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("All Metrics"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Filter fields")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { if sections.isEmpty { await load() } }
    }

    private var filtered: [Section] {
        guard !query.isEmpty else { return sections }
        let q = query.lowercased()
        return sections.compactMap { s in
            let rows = s.rows.filter { $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
            return rows.isEmpty ? nil : Section(title: s.title, rows: rows)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var result: [Section] = []

        if session.isLoggedIn {
            let g = GarminClient(session: session)
            let today = Date()
            if let d = try? await g.dailySummary(date: today) {
                result.append(Section(title: "Garmin · Daily Summary", rows: flatten(d)))
            }
            if let fa = try? await g.fitnessAge(date: today) {
                result.append(Section(title: "Garmin · Fitness Age", rows: flatten(fa)))
            }
        }

        if ouraSession.isConnected {
            let o = OuraClient(session: ouraSession)
            let start = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
            let collections = ["daily_readiness", "daily_sleep", "sleep", "daily_activity",
                               "daily_stress", "daily_spo2", "daily_resilience",
                               "daily_cardiovascular_age", "vO2_max"]
            for name in collections {
                if let rows = try? await o.dailyCollection(name, start: start, end: Date()), let latest = rows.last {
                    result.append(Section(title: "Oura · \(name)", rows: flatten(latest)))
                }
            }
            if let info = try? await o.personalInfo() {
                result.append(Section(title: "Oura · personal_info", rows: flatten(info)))
            }
        }

        sections = result
    }

    /// Flattens a JSON dict into sorted (key, value) rows, stringifying nested
    /// values so nothing is dropped.
    private func flatten(_ dict: [String: Any]) -> [(key: String, value: String)] {
        dict.keys.sorted().map { key in
            (key, stringify(dict[key]))
        }
    }

    private func stringify(_ value: Any?) -> String {
        switch value {
        case let n as NSNumber: return n.stringValue
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let d as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: d),
               let s = String(data: data, encoding: .utf8) { return s.count > 120 ? String(s.prefix(120)) + "…" : s }
            return "{…}"
        case let a as [Any]: return "[\(a.count)]"
        case is NSNull, .none: return "—"
        default: return "\(value!)"
        }
    }
}
