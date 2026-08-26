import SwiftUI
import SwiftData

/// Editable workout blocks (Gym Day, Calisthenics, Skills). Each block is
/// free-text you can edit; add/remove blocks as needed. Synced to the cloud.
struct WorkoutSection: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    @Query(sort: \WorkoutBlock.order) private var blocks: [WorkoutBlock]
    @State private var editing: WorkoutBlock?

    var body: some View {
        List {
            ForEach(blocks) { block in
                Button { editing = block } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(block.title).font(.headline).foregroundStyle(.primary)
                        Text(block.content)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                    }
                }
            }
            .onDelete { idx in idx.map { blocks[$0] }.forEach(context.delete); save() }
            Button {
                let b = WorkoutBlock(title: "New Block", content: "", order: (blocks.last?.order ?? -1) + 1)
                context.insert(b); save(); editing = b
            } label: { Label("Add Block", systemImage: "plus") }
        }
        .sheet(item: $editing) { block in
            NavigationStack {
                Form {
                    Section("Title") { TextField("Title", text: Bindable(block).title) }
                    Section("Content") {
                        TextEditor(text: Bindable(block).content)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 280)
                    }
                }
                .navigationTitle(Text("Edit Workout"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { save(); editing = nil }
                    }
                }
            }
        }
    }

    private func save() {
        try? context.save()
        cloud.requestBackup(context: context)
    }
}

/// One-time seed content for the workout blocks (the user's routine).
enum WorkoutSeed {
    static let blocks: [(String, String)] = [
        ("Gym Day", """
        Squat elevated heels — S1 / S2 / S3 / S4 / S5 — Notes
        Aug 20: 6x50 · 6x50 · 6x50 · 6x50 · — — good
        Aug 24: 8x50 · 8x50 · 8x50 · 8x50 · — — tired
        Aug 28: 8x50 · 8x50 · 8x50 · 8x50 · 3x50 — power day
        """),
        ("Calisthenics Day", """
        (S1 / S2 / S3 / S4)
        Pullups: 10 / 10 / 10 / —
        Squats: 15 / 15 / 15 / —
        Pushups: 10 / 10 / 10 / —
        RDL: 15 / 15 / 15 / —
        Pike pushups: 20 / 20 / 20 / —
        Tucked FL Inverted rows: 10 / 10 / 10 / —
        Lunges: 10 / 10 / 10 / —
        Glute bridge: 10 / 10 / 10 / —
        FL Raise or Leg raises: 10 / 10 / 10 / —
        Bonus Burpees: 5 / 5 / 5 / —
        """),
        ("Skills", """
        Skills: Levers · MU (Rings or regular) · HS (with press up) · Pistol squats · OAPU · Flag

        Upper: Chest One Notch Up · Pullups · Seated Rows · Military Press · Face Pulls · Lateral Raise
        Lower: Squat elevated heels · RDL · Glute bridge · Calf/Ankle Raise
        Core: Dragon Flag · Weighted Abs · One arm Hanging Leg Raise · L Sits · Window Wipers
        Cardio: Burpees · Pushing heavy object · Sprint
        """),
    ]
}
