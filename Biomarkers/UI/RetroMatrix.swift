import SwiftUI
import SwiftData

/// Mobile-friendly retro: a list of domains; tap one to see its full history
/// of review-period entries (readable, editable). Import brings in your
/// existing spreadsheet so old data shows up.
struct RetroMatrix: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    @Query(sort: \RetroRow.order) private var rows: [RetroRow]
    @Query(sort: \RetroColumn.order) private var columns: [RetroColumn]
    @Query private var cells: [RetroCell]

    @State private var showImport = false
    @State private var showAddRow = false
    @State private var newName = ""
    @State private var review: ReviewTarget?

    struct ReviewTarget: Identifiable { let id: String }

    private var cellsByRow: [String: [String: String]] {
        var map: [String: [String: String]] = [:]
        for c in cells where !c.text.isEmpty {
            map[c.rowId, default: [:]][c.colId] = c.text
        }
        return map
    }

    enum Mode: String, CaseIterable { case byDate = "By Date", bySection = "By Section" }
    @State private var mode: Mode = .byDate

    var body: some View {
        List {
            Section {
                Button { startTodayReview() } label: {
                    Label("Start a Review", systemImage: "square.and.pencil").font(.headline)
                }
                if !columns.isEmpty {
                    Menu {
                        ForEach(columns.reversed()) { col in
                            Button(col.label) { review = ReviewTarget(id: col.id) }
                        }
                    } label: {
                        Label("Review a specific period", systemImage: "calendar")
                    }
                }
            }

            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            if mode == .byDate {
                Section("Dates") {
                    ForEach(columns.reversed()) { col in
                        NavigationLink { RetroDateView(columnId: col.id) } label: { Text(col.label) }
                    }
                }
            } else {
                Section {
                    ForEach(rows) { row in
                        NavigationLink {
                            RetroDomainDetail(row: row, columns: columns)
                        } label: {
                            let filled = cellsByRow[row.id]?.count ?? 0
                            let latest = latestEntry(for: row)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(row.name).font(.headline)
                                        .foregroundStyle(row.excluded ? .secondary : .primary)
                                    if row.excluded {
                                        Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text("\(filled)").font(.caption).foregroundStyle(.secondary)
                                }
                                if let latest {
                                    Text(latest).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .contextMenu {
                            Button {
                                row.excluded.toggle(); try? context.save(); cloud.requestBackup(context: context)
                            } label: {
                                Label(row.excluded ? "Include in reviews" : "Exclude from reviews",
                                      systemImage: row.excluded ? "eye" : "eye.slash")
                            }
                        }
                    }
                    .onDelete { idx in idx.map { rows[$0] }.forEach(context.delete); try? context.save() }
                } header: {
                    Text("Sections")
                } footer: {
                    Text("Long-press a section to exclude it from reviews.")
                }
            }
        }
        .navigationTitle(Text("Retro"))
        .sheet(item: $review) { target in RetroReview(columnId: target.id) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showImport = true } label: { Image(systemName: "square.and.arrow.down") }
                Button { newName = ""; showAddRow = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImport) { RetroImportView() }
        .alert("Add Domain", isPresented: $showAddRow) {
            TextField("Name", text: $newName)
            Button("Add") {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { return }
                context.insert(RetroRow(name: n, order: (rows.last?.order ?? -1) + 1))
                try? context.save()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Finds or creates a column for today and opens the guided review.
    private func startTodayReview() {
        let label = Date().formatted(.dateTime.month(.abbreviated).day().year())
        if let existing = columns.first(where: { $0.label == label }) {
            review = ReviewTarget(id: existing.id)
        } else {
            let col = RetroColumn(label: label, order: (columns.last?.order ?? -1) + 1)
            context.insert(col)
            try? context.save()
            review = ReviewTarget(id: col.id)
        }
    }

    /// The most recent non-empty entry (last column in order that has text).
    private func latestEntry(for row: RetroRow) -> String? {
        guard let byCol = cellsByRow[row.id] else { return nil }
        for col in columns.reversed() {
            if let t = byCol[col.id], !t.isEmpty { return t }
        }
        return nil
    }
}

/// One domain's full timeline of period entries.
struct RetroDomainDetail: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    let row: RetroRow
    let columns: [RetroColumn]
    @Query private var cells: [RetroCell]
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable { let col: RetroColumn; var id: String { col.id } }

    private func text(for col: RetroColumn) -> String {
        let id = RetroCell.makeId(rowId: row.id, colId: col.id)
        return cells.first { $0.id == id }?.text ?? ""
    }

    var body: some View {
        List {
            ForEach(columns) { col in
                let t = text(for: col)
                Button { editing = EditTarget(col: col) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(col.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(t.isEmpty ? "Tap to add…" : t)
                            .font(.callout)
                            .foregroundStyle(t.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .navigationTitle(Text(row.name))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { target in
            CellEditor(title: row.name, subtitle: target.col.label, text: text(for: target.col)) { newText in
                setCell(colId: target.col.id, text: newText)
            }
        }
    }

    private func setCell(colId: String, text: String) {
        let id = RetroCell.makeId(rowId: row.id, colId: colId)
        let predicate = #Predicate<RetroCell> { $0.id == id }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            existing.text = text
        } else if !text.isEmpty {
            context.insert(RetroCell(rowId: row.id, colId: colId, text: text))
        }
        try? context.save()
        cloud.requestBackup(context: context)
    }
}

struct CellEditor: View {
    let title: String
    let subtitle: String
    @State var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body).padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }
            .padding()
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(text); dismiss() } }
            }
        }
    }
}
