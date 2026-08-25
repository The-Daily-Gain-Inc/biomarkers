import SwiftUI
import SwiftData

/// Life-planning hub: Dreams (+ read-only profile), editable Longevity rules,
/// and the Retro matrix — all backed by SwiftData and seeded on first launch.
struct LifeView: View {
    enum Tab: String, CaseIterable { case dreams = "Dreams", longevity = "Longevity", retro = "Retro" }

    @Environment(\.modelContext) private var context
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
                case .retro: RetroMatrix()
                }
            }
            .swipeSegments($tab)
            .navigationTitle(Text("Life"))
            .task { seedIfNeeded() }
        }
    }

    private func seedIfNeeded() {
        // One-time: load the real history from the bundled CSV, replacing any
        // earlier empty skeleton (this runs once, tracked by the flag).
        if !UserDefaults.standard.bool(forKey: "retroCSVSeedV1") {
            try? context.delete(model: RetroCell.self)
            try? context.delete(model: RetroRow.self)
            try? context.delete(model: RetroColumn.self)
            if seedFromCSV() {
                UserDefaults.standard.set(true, forKey: "retroCSVSeedV1")
            } else {
                for (i, name) in RetroSeed.rows.enumerated() { context.insert(RetroRow(name: name, order: i)) }
                for (i, label) in RetroSeed.columns.enumerated() { context.insert(RetroColumn(label: label, order: i)) }
            }
        }
        if dreams.isEmpty {
            for (i, d) in RetroSeed.dreams.enumerated() {
                context.insert(RetroDream(title: d.0, status: d.1, rationale: d.2, order: i))
            }
        }
        let ruleCount = (try? context.fetchCount(FetchDescriptor<LongevityRule>())) ?? 0
        if ruleCount == 0 {
            for (i, r) in RetroSeed.longevityRules.enumerated() { context.insert(LongevityRule(text: r, order: i)) }
        }
        try? context.save()
    }

    /// Seeds the retro matrix (domains, periods, and all historical cells)
    /// from the bundled RetroSeed.csv. Returns false if the file is missing.
    private func seedFromCSV() -> Bool {
        guard let url = Bundle.main.url(forResource: "RetroSeed", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let records = RetroImportView.parseDelimited(text, delimiter: ",")
        guard records.count >= 2 else { return false }

        let header = records[0]
        var colByIndex: [Int: RetroColumn] = [:]
        for idx in 1..<header.count {
            let label = header[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let col = RetroColumn(label: label, order: idx - 1)
            context.insert(col)
            colByIndex[idx] = col
        }

        var order = 0
        for record in records.dropFirst() {
            guard let first = record.first else { continue }
            let name = first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let row = RetroRow(name: name, order: order); order += 1
            context.insert(row)
            for idx in 1..<record.count {
                guard let col = colByIndex[idx] else { continue }
                let value = record[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value != "-" else { continue }
                context.insert(RetroCell(rowId: row.id, colId: col.id, text: value))
            }
        }
        return true
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
                    Button("Done") { try? context.save(); dismiss() }
                }
            }
        }
    }
}

// MARK: - Longevity

struct LongevitySection: View {
    @Environment(\.modelContext) private var context
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
                            Button("Done") { try? context.save(); editing = nil }
                        }
                    }
            }
        }
    }
}
