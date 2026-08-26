import SwiftUI

/// A user-defined biomarker. Values are stored in DailyMetric under `id`, just
/// like the built-in manual metrics, so custom ones flow into Log, the
/// dashboard, Trends, and detail views automatically.
struct CustomMetricDef: Codable, Identifiable, Equatable {
    var id: String            // "custom_<uuid>"
    var name: String
    var unit: String
    var higherIsBetter: Bool
    var decimals: Int         // 0 or 1
}

enum CustomMetricStore {
    private static let key = "customMetrics"

    static func all() -> [CustomMetricDef] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([CustomMetricDef].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [CustomMetricDef]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func newId() -> String { "custom_\(UUID().uuidString.prefix(8))" }
}

struct CustomBiomarkersView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    @State private var metrics: [CustomMetricDef] = CustomMetricStore.all()
    @State private var editing: CustomMetricDef?

    var body: some View {
        List {
            Section {
                ForEach(metrics) { m in
                    Button { editing = m } label: {
                        HStack {
                            Text(m.name).foregroundStyle(.primary)
                            Spacer()
                            if !m.unit.isEmpty { Text(m.unit).font(.caption).foregroundStyle(.secondary) }
                            Image(systemName: m.higherIsBetter ? "arrow.up" : "arrow.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    metrics.remove(atOffsets: idx); persist()
                }
                Button {
                    let new = CustomMetricDef(id: CustomMetricStore.newId(), name: "", unit: "", higherIsBetter: true, decimals: 0)
                    editing = new
                } label: { Label("Add Biomarker", systemImage: "plus") }
            } footer: {
                Text("Custom biomarkers appear in Log, the dashboard, and Trends. Log values with the pencil on the dashboard.")
            }
        }
        .navigationTitle(Text("Custom Biomarkers"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { def in
            CustomMetricEditor(def: def) { saved in
                if let i = metrics.firstIndex(where: { $0.id == saved.id }) { metrics[i] = saved }
                else { metrics.append(saved) }
                persist()
            }
        }
    }

    private func persist() {
        CustomMetricStore.save(metrics)
        cloud.requestBackup(context: context)
    }
}

struct CustomMetricEditor: View {
    @State var def: CustomMetricDef
    let onSave: (CustomMetricDef) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Ear Age)", text: $def.name)
                TextField("Unit (optional, e.g. mg/dL)", text: $def.unit)
                Toggle("Higher is better", isOn: $def.higherIsBetter)
                Picker("Decimals", selection: $def.decimals) {
                    Text("0").tag(0); Text("1").tag(1)
                }
            }
            .navigationTitle(Text("Biomarker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !def.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        onSave(def); dismiss()
                    }
                }
            }
        }
    }
}
