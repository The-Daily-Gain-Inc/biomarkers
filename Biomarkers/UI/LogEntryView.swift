import SwiftUI
import SwiftData

/// Manual data entry for a chosen date. Values are written to the same
/// DailyMetric cache as everything else, so they flow into the dashboard and
/// Trends. Change the date to backfill / bulk-add history.
struct LogEntryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var fields: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .onChange(of: date) { _, _ in loadExisting() }
                }
                Section {
                    ForEach(DashboardModel.manualMetrics, id: \.key) { m in
                        HStack {
                            Text(LocalizedStringKey(m.label))
                            Spacer()
                            TextField("—", text: Binding(
                                get: { fields[m.key] ?? "" },
                                set: { fields[m.key] = $0 }
                            ))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            if let unit = m.unit {
                                Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                            } else {
                                Spacer().frame(width: 44)
                            }
                        }
                    }
                } footer: {
                    Text("Leave a field blank to skip it. Blood pressure is two fields; enter both.")
                }
            }
            .navigationTitle(Text("Log Data"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private func loadExisting() {
        let day = Calendar.current.startOfDay(for: date)
        var next: [String: String] = [:]
        for m in DashboardModel.manualMetrics {
            let id = DailyMetric.makeId(day: day, key: m.key)
            let predicate = #Predicate<DailyMetric> { $0.id == id }
            if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
                // Show ints without a trailing .0.
                next[m.key] = existing.value == existing.value.rounded()
                    ? String(Int(existing.value)) : String(existing.value)
            }
        }
        fields = next
    }

    private func save() {
        let day = Calendar.current.startOfDay(for: date)
        for m in DashboardModel.manualMetrics {
            guard let raw = fields[m.key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                  let value = Double(raw) else { continue }
            let id = DailyMetric.makeId(day: day, key: m.key)
            let predicate = #Predicate<DailyMetric> { $0.id == id }
            if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
                existing.value = value
                existing.fetchedAt = Date()
            } else {
                context.insert(DailyMetric(day: day, metricKey: m.key, value: value))
            }
        }
        try? context.save()
        cloud.requestBackup(context: context)
        dismiss()
    }
}
