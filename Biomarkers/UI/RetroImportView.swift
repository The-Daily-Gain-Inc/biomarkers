import SwiftUI
import SwiftData

/// Paste your spreadsheet (tab-separated, as copied from Google Sheets/Excel)
/// to import the full retro history. The first row is the header
/// (Domain, then period labels); each following row is a domain and its cells.
/// Matches domains/periods by name — creating any that don't exist — and fills
/// the cells, so your old data appears in the grid.
struct RetroImportView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RetroRow.order) private var rows: [RetroRow]
    @Query(sort: \RetroColumn.order) private var columns: [RetroColumn]
    @State private var pasted = ""
    @State private var result: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste your retro grid copied from your spreadsheet (Select all → Copy). First row must be: Domain, then the period columns.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $pasted)
                    .font(.system(size: 12, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                if let result {
                    Text(result).font(.footnote).foregroundStyle(.green)
                }
            }
            .padding()
            .navigationTitle(Text("Import Retro"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { runImport() }.disabled(pasted.isEmpty)
                }
            }
        }
    }

    private func runImport() {
        let records = Self.parseDelimited(pasted, delimiter: "\t")
        guard records.count >= 2, let header = records.first else {
            result = "Nothing to import — need a header row and at least one domain."
            return
        }
        // Header: [Domain, label1, label2, …]. Resolve/create columns by label.
        var colByIndex: [Int: RetroColumn] = [:]
        var existingCols = Dictionary(columns.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        var nextColOrder = (columns.map(\.order).max() ?? -1) + 1
        for idx in 1..<header.count {
            let label = header[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            if let c = existingCols[label] {
                colByIndex[idx] = c
            } else {
                let c = RetroColumn(label: label, order: nextColOrder); nextColOrder += 1
                context.insert(c); existingCols[label] = c; colByIndex[idx] = c
            }
        }

        var existingRows = Dictionary(rows.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var nextRowOrder = (rows.map(\.order).max() ?? -1) + 1
        var filledCells = 0, touchedRows = 0

        for record in records.dropFirst() {
            guard let first = record.first else { continue }
            let name = first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let row: RetroRow
            if let r = existingRows[name] { row = r }
            else { row = RetroRow(name: name, order: nextRowOrder); nextRowOrder += 1; context.insert(row); existingRows[name] = row }
            touchedRows += 1

            for idx in 1..<record.count {
                guard let col = colByIndex[idx] else { continue }
                let value = record[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value != "-" else { continue }
                let id = RetroCell.makeId(rowId: row.id, colId: col.id)
                let predicate = #Predicate<RetroCell> { $0.id == id }
                if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
                    existing.text = value
                } else {
                    context.insert(RetroCell(rowId: row.id, colId: col.id, text: value))
                }
                filledCells += 1
            }
        }
        try? context.save()
        cloud.requestBackup(context: context)
        result = "Imported \(filledCells) cells across \(touchedRows) domains."
    }

    /// CSV/TSV parser: fields may be quoted; quotes escape as "" and may span
    /// newlines. Returns rows of fields.
    static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false; i += 1; continue
                }
                field.append(c); i += 1; continue
            } else {
                switch c {
                case "\"": inQuotes = true
                case delimiter: record.append(field); field = ""
                case "\r": break
                case "\n": record.append(field); rows.append(record); record = []; field = ""
                default: field.append(c)
                }
                i += 1
            }
        }
        record.append(field)
        if record.count > 1 || !(record.first ?? "").isEmpty { rows.append(record) }
        return rows
    }
}
