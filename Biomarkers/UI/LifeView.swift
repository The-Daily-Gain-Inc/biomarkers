import SwiftUI
import SwiftData

/// Life-planning hub: Dreams (+ read-only profile), editable Longevity rules,
/// and the Retro matrix — all backed by SwiftData and seeded on first launch.
struct LifeView: View {
    enum Tab: String, CaseIterable { case dreams = "Dreams", longevity = "Longevity", workout = "Workout", retro = "Retro" }

    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    @State private var tab: Tab = .dreams
    @Query(sort: \RetroRow.order) private var rows: [RetroRow]
    @Query(sort: \RetroDream.order) private var dreams: [RetroDream]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)

                switch tab {
                case .dreams: DreamsSection()
                case .longevity: LongevitySection()
                case .workout: WorkoutSection()
                case .retro: RetroMatrix()
                }
            }
            .swipeSegments($tab)
            .navigationTitle(Text("Life"))
        }
    }
}

// MARK: - Dreams

struct DreamsSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RetroDream.order) private var dreams: [RetroDream]
    @State private var editing: RetroDream?

    var body: some View {
        List {
            Section("Dreams") {
                ForEach(dreams) { dream in
                    Button { editing = dream } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(dream.title).font(.headline).foregroundStyle(.primary)
                                Spacer()
                                Text(dream.status)
                                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(.green.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                            Text(dream.rationale)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .onDelete { idx in idx.map { dreams[$0] }.forEach(context.delete); try? context.save() }
                Button {
                    let d = RetroDream(title: "New Dream", status: "Draft", rationale: "", order: (dreams.last?.order ?? -1) + 1)
                    context.insert(d); try? context.save(); editing = d
                } label: { Label("Add Dream", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { DreamEditor(dream: $0) }
    }
}

struct DreamEditor: View {
    @Bindable var dream: RetroDream
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync

    var body: some View {
        NavigationStack {
            Form {
                Section("Dream") { TextField("Title", text: $dream.title) }
                Section("Status") { TextField("Status", text: $dream.status) }
                Section("Rationale") {
                    TextEditor(text: $dream.rationale).frame(minHeight: 160)
                }
            }
            .navigationTitle(Text("Edit Dream"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { try? context.save(); cloud.requestBackup(context: context); dismiss() }
                }
            }
        }
    }
}

// MARK: - Longevity

struct LongevitySection: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloud: CloudSync
    @Query(sort: \LongevityRule.order) private var rules: [LongevityRule]
    @State private var editing: LongevityRule?

    var body: some View {
        List {
            ForEach(rules) { rule in
                Button { editing = rule } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "leaf.fill").foregroundStyle(.green).font(.caption)
                        Text(rule.text).foregroundStyle(.primary)
                    }
                }
            }
            .onDelete { idx in idx.map { rules[$0] }.forEach(context.delete); try? context.save() }
            Button {
                let r = LongevityRule(text: "New rule", order: (rules.last?.order ?? -1) + 1)
                context.insert(r); try? context.save(); editing = r
            } label: { Label("Add Rule", systemImage: "plus") }
        }
        .sheet(item: $editing) { rule in
            NavigationStack {
                Form { TextEditor(text: Bindable(rule).text).frame(minHeight: 160) }
                    .navigationTitle(Text("Edit Rule"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { try? context.save(); cloud.requestBackup(context: context); editing = nil }
                        }
                    }
            }
        }
    }
}
