import SwiftUI
import SwiftData

/// Guided retro entry: pick (or create) a review date, then step through each
/// domain one at a time with a large editor and Next/Previous. Add new
/// sections (domains) on the fly.
struct RetroReview: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloud: CloudSync
    @Query(sort: \RetroRow.order) private var rows: [RetroRow]
    @Query(sort: \RetroColumn.order) private var columns: [RetroColumn]
    @Query private var cells: [RetroCell]

    let columnId: String
    @State private var index = 0
    @State private var showAddSection = false
    @State private var newSection = ""

    private var column: RetroColumn? { columns.first { $0.id == columnId } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    ContentUnavailableView("No sections yet", systemImage: "square.stack",
                                           description: Text("Add a section to start your review."))
                } else {
                    TabView(selection: $index) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            page(row: row).tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut, value: index)

                    controls
                }
            }
            .navigationTitle(Text(column?.label ?? "Review"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { save(); dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { newSection = ""; showAddSection = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("Add Section", isPresented: $showAddSection) {
                TextField("Name", text: $newSection)
                Button("Add") { addSection() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func page(row: RetroRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(index + 1) of \(rows.count)")
                .font(.caption).foregroundStyle(.secondary)
            Text(row.name).font(.title2.weight(.semibold))
            TextEditor(text: binding(for: row))
                .font(.body)
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxHeight: .infinity)
        }
        .padding()
    }

    private var controls: some View {
        HStack {
            Button {
                save(); withAnimation { index = max(0, index - 1) }
            } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(index == 0)
            Spacer()
            if index < rows.count - 1 {
                Button {
                    save(); withAnimation { index += 1 }
                } label: { Label("Next", systemImage: "chevron.right").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Finish") { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private func binding(for row: RetroRow) -> Binding<String> {
        Binding(
            get: {
                let id = RetroCell.makeId(rowId: row.id, colId: columnId)
                return cells.first { $0.id == id }?.text ?? ""
            },
            set: { newText in
                let id = RetroCell.makeId(rowId: row.id, colId: columnId)
                if let existing = cells.first(where: { $0.id == id }) {
                    existing.text = newText
                } else if !newText.isEmpty {
                    context.insert(RetroCell(rowId: row.id, colId: columnId, text: newText))
                }
            }
        )
    }

    private func addSection() {
        let name = newSection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        context.insert(RetroRow(name: name, order: (rows.last?.order ?? -1) + 1))
        try? context.save()
        // Jump to the new (last) section.
        DispatchQueue.main.async { index = rows.count - 1 }
    }

    private func save() {
        try? context.save()
        cloud.requestBackup(context: context)
    }
}
