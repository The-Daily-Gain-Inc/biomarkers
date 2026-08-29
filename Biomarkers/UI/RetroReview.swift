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
    @State private var showSections = false
    @State private var newSection = ""
    @FocusState private var editorFocused: Bool

    private var column: RetroColumn? { columns.first { $0.id == columnId } }
    private var reviewRows: [RetroRow] { rows.filter { !$0.excluded } }
    private var clampedIndex: Int { min(max(index, 0), max(0, reviewRows.count - 1)) }
    private var currentRow: RetroRow? {
        reviewRows.indices.contains(clampedIndex) ? reviewRows[clampedIndex] : nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let row = currentRow {
                    // A single page swapped by the Next/Previous buttons. Using a
                    // fresh view per index (via .id) resets the TextEditor's own
                    // scroll to the top each step — no paging gesture to fight the
                    // editor's internal scroll.
                    page(row: row)
                        .id(clampedIndex)
                        .transition(.push(from: .trailing))
                        .animation(.easeInOut, value: clampedIndex)

                    controls
                } else {
                    ContentUnavailableView("No sections yet", systemImage: "square.stack",
                                           description: Text("Add a section to start your review."))
                }
            }
            .navigationTitle(Text(column?.label ?? "Review"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { save(); dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { newSection = ""; showAddSection = true } label: {
                            Label("Add Section", systemImage: "plus")
                        }
                        Button { showSections = true } label: {
                            Label("Manage Sections", systemImage: "slider.horizontal.3")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert("Add Section", isPresented: $showAddSection) {
                TextField("Name", text: $newSection)
                Button("Add") { addSection() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showSections) { RetroSectionManager() }
            .onChange(of: reviewRows.count) { _, count in
                if index > count - 1 { index = max(0, count - 1) }
            }
        }
    }

    /// Move between sections: commit text, drop the keyboard so the transition
    /// isn't fighting an active editor, then step.
    private func step(to newIndex: Int) {
        save()
        editorFocused = false
        withAnimation { index = min(max(newIndex, 0), max(0, reviewRows.count - 1)) }
    }

    @ViewBuilder
    private func page(row: RetroRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(clampedIndex + 1) of \(reviewRows.count)")
                .font(.caption).foregroundStyle(.secondary)
            Text(row.name).font(.title2.weight(.semibold))
            TextEditor(text: binding(for: row))
                .font(.body)
                .focused($editorFocused)
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxHeight: .infinity)
        }
        .padding()
    }

    private var controls: some View {
        HStack {
            Button {
                step(to: clampedIndex - 1)
            } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(clampedIndex == 0)
            Spacer()
            if clampedIndex < reviewRows.count - 1 {
                Button {
                    step(to: clampedIndex + 1)
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
        DispatchQueue.main.async { index = reviewRows.count - 1 }
    }

    private func save() {
        try? context.save()
        cloud.requestBackup(context: context)
    }
}
