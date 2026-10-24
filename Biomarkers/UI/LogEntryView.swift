import SwiftUI
import SwiftData

/// Manual data entry for a chosen date. Values are written to the same
/// DailyMetric cache as everything else, so they flow into the dashboard and
/// Trends. Change the date to backfill history, or open "Past entries" to
/// jump to a day you already logged and fix it. Clearing a field deletes
/// that value; a note per day rides along.
struct LogEntryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var fields: [String: String] = [:]
    @State private var note = ""
    /// Snapshot of what was on disk when the day loaded, so saving knows
    /// which fields were cleared (→ delete) vs never set (→ skip).
    @State private var existingKeys: Set<String> = []
    @State private var hadNote = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .onChange(of: date) { _, _ in loadExisting() }
                    NavigationLink {
                        LoggedDaysView(selectedDay: $date)
                    } label: {
                        Label("Past entries", systemImage: "clock.arrow.circlepath")
                    }
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
                    Text(existingKeys.isEmpty
                         ? "Leave a field blank to skip it. Blood pressure is two fields; enter both."
                         : "Edit a value to change it. Clear a field to delete that day's value.")
                }
                Section("Note") {
                    TextField("How did the day go? Fasted, sick, new cuff…", text: $note, axis: .vertical)
                        .lineLimit(2...6)
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
        var keys: Set<String> = []
        for m in DashboardModel.manualMetrics {
            let id = DailyMetric.makeId(day: day, key: m.key)
            let predicate = #Predicate<DailyMetric> { $0.id == id }
            if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
                // Show ints without a trailing .0.
                next[m.key] = existing.value == existing.value.rounded()
                    ? String(Int(existing.value)) : String(existing.value)
                keys.insert(m.key)
            }
        }
        fields = next
        existingKeys = keys
        let noteId = DailyNote.makeId(day: day)
        let notePredicate = #Predicate<DailyNote> { $0.id == noteId }
        let existingNote = try? context.fetch(FetchDescriptor(predicate: notePredicate)).first
        note = existingNote?.text ?? ""
        hadNote = !(existingNote?.text.isEmpty ?? true)
    }

    private func save() {
        let day = Calendar.current.startOfDay(for: date)
        var removed: [String] = []
        for m in DashboardModel.manualMetrics {
            let raw = fields[m.key]?.trimmingCharacters(in: .whitespaces) ?? ""
            let id = DailyMetric.makeId(day: day, key: m.key)
            let predicate = #Predicate<DailyMetric> { $0.id == id }
            let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first
            if raw.isEmpty {
                // Cleared a value that was there → delete it (and tombstone
                // it in the cloud so a restore doesn't bring it back).
                if let existing, existingKeys.contains(m.key) {
                    context.delete(existing)
                    removed.append(id)
                }
                continue
            }
            guard let value = Double(raw) else { continue }
            if let existing {
                existing.value = value
                existing.fetchedAt = Date()
            } else {
                context.insert(DailyMetric(day: day, metricKey: m.key, value: value))
            }
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteId = DailyNote.makeId(day: day)
        let notePredicate = #Predicate<DailyNote> { $0.id == noteId }
        let existingNote = try? context.fetch(FetchDescriptor(predicate: notePredicate)).first
        var removedNotes: [String] = []
        if trimmedNote.isEmpty {
            if let existingNote { context.delete(existingNote); removedNotes.append(noteId) }
        } else if let existingNote {
            if existingNote.text != trimmedNote { existingNote.text = trimmedNote; existingNote.touch() }
        } else {
            context.insert(DailyNote(day: day, text: trimmedNote))
        }

        try? context.save()
        if !removed.isEmpty { Task { await cloud.softDelete(collection: "dailyMetrics", ids: removed) } }
        if !removedNotes.isEmpty { Task { await cloud.softDelete(collection: "dailyNotes", ids: removedNotes) } }
        cloud.requestBackup(context: context)
        dismiss()
    }
}

/// Every day that has manually logged values or a note, newest first. Tap a
/// day to load it into the editor; swipe to delete the whole day.
struct LoggedDaysView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDay: Date

    @Query(sort: \DailyNote.day, order: .reverse) private var notes: [DailyNote]
    @State private var days: [LoggedDay] = []

    struct LoggedDay: Identifiable {
        let day: Date
        var values: [(label: String, text: String)]
        var note: String
        var id: Date { day }
    }

    var body: some View {
        List {
            if days.isEmpty {
                ContentUnavailableView("Nothing logged yet",
                                       systemImage: "square.and.pencil",
                                       description: Text("Values you enter by hand show up here, with their notes."))
            }
            ForEach(days) { entry in
                Button {
                    selectedDay = entry.day
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                            .font(.subheadline.weight(.semibold))
                        if !entry.values.isEmpty {
                            Text(entry.values.map { "\(String(localized: String.LocalizationValue($0.label))) \($0.text)" }
                                    .joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if !entry.note.isEmpty {
                            Label(entry.note, systemImage: "text.quote")
                                .font(.footnote).foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) { delete(entry) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(Text("Past entries"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: notes.count) { _, _ in load() }
    }

    private func load() {
        let manual = DashboardModel.manualMetrics
        let keys = Set(manual.map(\.key))
        let labels = Dictionary(manual.map { ($0.key, $0.label) }, uniquingKeysWith: { a, _ in a })
        let metrics = ((try? context.fetch(FetchDescriptor<DailyMetric>())) ?? [])
            .filter { keys.contains($0.metricKey) }
        var byDay: [Date: LoggedDay] = [:]
        for m in metrics {
            let text = m.value == m.value.rounded() ? String(Int(m.value)) : String(m.value)
            byDay[m.day, default: LoggedDay(day: m.day, values: [], note: "")]
                .values.append((labels[m.metricKey] ?? m.metricKey, text))
        }
        for n in notes where !n.text.isEmpty {
            byDay[n.day, default: LoggedDay(day: n.day, values: [], note: "")].note = n.text
        }
        // Keep the editor's field order inside each day.
        let order = Dictionary(manual.enumerated().map { ($1.label, $0) }, uniquingKeysWith: { a, _ in a })
        days = byDay.values
            .map { day in
                var d = day
                d.values.sort { (order[$0.label] ?? 99) < (order[$1.label] ?? 99) }
                return d
            }
            .sorted { $0.day > $1.day }
    }

    private func delete(_ entry: LoggedDay) {
        let day = entry.day
        var removed: [String] = []
        for m in DashboardModel.manualMetrics {
            let id = DailyMetric.makeId(day: day, key: m.key)
            let predicate = #Predicate<DailyMetric> { $0.id == id }
            if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
                context.delete(existing)
                removed.append(id)
            }
        }
        let noteId = DailyNote.makeId(day: day)
        let notePredicate = #Predicate<DailyNote> { $0.id == noteId }
        var removedNotes: [String] = []
        if let n = try? context.fetch(FetchDescriptor(predicate: notePredicate)).first {
            context.delete(n)
            removedNotes.append(noteId)
        }
        try? context.save()
        if !removed.isEmpty { Task { await cloud.softDelete(collection: "dailyMetrics", ids: removed) } }
        if !removedNotes.isEmpty { Task { await cloud.softDelete(collection: "dailyNotes", ids: removedNotes) } }
        cloud.requestBackup(context: context)
        withAnimation { days.removeAll { $0.id == entry.id } }
    }
}
