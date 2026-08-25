import SwiftUI
import SwiftData

/// The editable retro matrix: domains as rows, review periods as columns,
/// free-text cells. Frozen first column, horizontally scrolling periods.
struct RetroMatrix: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RetroRow.order) private var rows: [RetroRow]
    @Query(sort: \RetroColumn.order) private var columns: [RetroColumn]
    @Query private var cells: [RetroCell]

    @State private var editing: EditTarget?
    @State private var showAddColumn = false
    @State private var showAddRow = false
    @State private var newLabel = ""

    private let rowHeight: CGFloat = 66
    private let colWidth: CGFloat = 150
    private let nameWidth: CGFloat = 120
    private let headerHeight: CGFloat = 40

    struct EditTarget: Identifiable {
        let rowId: String; let colId: String; let rowName: String; let colLabel: String
        var id: String { "\(rowId)|\(colId)" }
    }

    private var cellText: [String: String] {
        Dictionary(cells.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                frozenColumn
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 0) {
                        ForEach(columns) { col in columnView(col) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { newLabel = ""; showAddRow = true } label: { Label("Domain", systemImage: "plus") }
                Spacer()
                Button { newLabel = ""; showAddColumn = true } label: { Label("Period", systemImage: "plus") }
            }
            .font(.subheadline)
            .padding(.horizontal).padding(.vertical, 8)
            .background(.regularMaterial)
        }
        .sheet(item: $editing) { target in cellEditor(target) }
        .alert("Add Period", isPresented: $showAddColumn) {
            TextField("Label (e.g. September 5)", text: $newLabel)
            Button("Add") { addColumn() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Add Domain", isPresented: $showAddRow) {
            TextField("Name", text: $newLabel)
            Button("Add") { addRow() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var frozenColumn: some View {
        VStack(spacing: 0) {
            Text("Domain")
                .font(.caption2.weight(.semibold))
                .frame(width: nameWidth, height: headerHeight)
                .background(Color(.secondarySystemBackground))
            ForEach(rows) { row in
                Text(row.name)
                    .font(.caption).lineLimit(3).minimumScaleFactor(0.8)
                    .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                    .padding(.horizontal, 6)
                    .background(Color(.secondarySystemBackground))
                    .overlay(alignment: .bottom) { Divider() }
                    .contextMenu { Button("Delete Domain", role: .destructive) { delete(row) } }
            }
        }
    }

    private func columnView(_ col: RetroColumn) -> some View {
        VStack(spacing: 0) {
            Text(col.label)
                .font(.caption2.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                .frame(width: colWidth, height: headerHeight)
                .overlay(alignment: .bottom) { Divider() }
                .contextMenu { Button("Delete Period", role: .destructive) { delete(col) } }
            ForEach(rows) { row in
                let id = RetroCell.makeId(rowId: row.id, colId: col.id)
                let text = cellText[id] ?? ""
                Button {
                    editing = EditTarget(rowId: row.id, colId: col.id, rowName: row.name, colLabel: col.label)
                } label: {
                    Text(text.isEmpty ? "—" : text)
                        .font(.caption2)
                        .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                        .frame(width: colWidth, height: rowHeight, alignment: .topLeading)
                        .padding(6)
                        .lineLimit(4)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private func cellEditor(_ target: EditTarget) -> some View {
        let id = RetroCell.makeId(rowId: target.rowId, colId: target.colId)
        return CellEditor(
            title: target.rowName,
            subtitle: target.colLabel,
            text: cellText[id] ?? "",
            onSave: { newText in setCell(rowId: target.rowId, colId: target.colId, text: newText) }
        )
    }

    // MARK: - Mutations

    private func setCell(rowId: String, colId: String, text: String) {
        let id = RetroCell.makeId(rowId: rowId, colId: colId)
        let predicate = #Predicate<RetroCell> { $0.id == id }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            existing.text = text
        } else if !text.isEmpty {
            context.insert(RetroCell(rowId: rowId, colId: colId, text: text))
        }
        try? context.save()
    }

    private func addColumn() {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        context.insert(RetroColumn(label: label, order: (columns.last?.order ?? -1) + 1))
        try? context.save()
    }

    private func addRow() {
        let name = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        context.insert(RetroRow(name: name, order: (rows.last?.order ?? -1) + 1))
        try? context.save()
    }

    private func delete(_ row: RetroRow) { context.delete(row); try? context.save() }
    private func delete(_ col: RetroColumn) { context.delete(col); try? context.save() }
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
                    .font(.body)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }
            .padding()
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(text); dismiss() }
                }
            }
        }
    }
}
