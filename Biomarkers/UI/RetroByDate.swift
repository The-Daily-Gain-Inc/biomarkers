import SwiftUI
import SwiftData

/// Pick a review date to read everything journaled on that date.
struct RetroDatesList: View {
    @Query(sort: \RetroColumn.order) private var columns: [RetroColumn]

    var body: some View {
        List {
            ForEach(columns.reversed()) { col in
                NavigationLink {
                    RetroDateView(columnId: col.id)
                } label: {
                    Text(col.label)
                }
            }
        }
        .navigationTitle(Text("By Date"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// All sections' entries for one date — read them at a glance, tap to edit.
struct RetroDateView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    @Query(sort: \RetroRow.order) private var rows: [RetroRow]
    @Query(sort: \RetroColumn.order) private var columns: [RetroColumn]
    @Query private var cells: [RetroCell]
    let columnId: String
    @State private var editing: RetroRow?

    private var column: RetroColumn? { columns.first { $0.id == columnId } }

    private func text(for row: RetroRow) -> String {
        let id = RetroCell.makeId(rowId: row.id, colId: columnId)
        return cells.first { $0.id == id }?.text ?? ""
    }

    var body: some View {
        List {
            ForEach(rows) { row in
                let t = text(for: row)
                if !t.isEmpty {
                    Section {
                        Button { editing = row } label: {
                            Text(t).font(.callout).foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } header: {
                        Text(row.name).textCase(nil).font(.subheadline.weight(.semibold))
                    }
                }
            }
            if rows.allSatisfy({ text(for: $0).isEmpty }) {
                Text("Nothing journaled for this date yet.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text(column?.label ?? "Date"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { row in
            CellEditor(title: row.name, subtitle: column?.label ?? "", text: text(for: row)) { newText in
                let id = RetroCell.makeId(rowId: row.id, colId: columnId)
                if let existing = cells.first(where: { $0.id == id }) { existing.text = newText; existing.touch() }
                else if !newText.isEmpty { context.insert(RetroCell(rowId: row.id, colId: columnId, text: newText)) }
                try? context.save()
                cloud.requestBackup(context: context)
            }
        }
    }
}
