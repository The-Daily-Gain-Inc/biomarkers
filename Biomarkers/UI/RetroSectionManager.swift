import SwiftUI
import SwiftData

/// Toggle which retro sections are active. Disabled sections are skipped when
/// creating or stepping through a review; their existing entries are kept.
struct RetroSectionManager: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloud: CloudSync
    @Query(sort: \RetroRow.order) private var rows: [RetroRow]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if rows.isEmpty {
                        Text("No sections yet.").foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        Toggle(isOn: Binding(
                            get: { !row.excluded },
                            set: { on in
                                row.excluded = !on
                                try? context.save()
                                cloud.requestBackup(context: context)
                            }
                        )) {
                            Text(row.name)
                        }
                    }
                } header: {
                    Text("Show in reviews")
                } footer: {
                    Text("Sections turned off won't appear when you create or step through a review. Their existing entries are kept.")
                }
            }
            .navigationTitle(Text("Review Sections"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
