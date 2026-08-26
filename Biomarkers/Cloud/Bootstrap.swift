import Foundation
import SwiftData

/// One place that seeds the bundled historical data at launch (after the
/// cloud restore). Self-healing: re-imports whenever a store is empty, so
/// missing data comes back rather than staying blank behind a stale flag.
enum Bootstrap {
    /// Returns true if it force-reimported retro (so the caller can also
    /// clean the cloud copy, which merge-writes never delete on their own).
    @MainActor
    @discardableResult
    static func run(context: ModelContext) -> Bool {
        // Retro — force a clean wipe+reimport once (retroReimportV5), then
        // self-heal whenever there are no cells.
        var forcedRetro = false
        let cellCount = (try? context.fetchCount(FetchDescriptor<RetroCell>())) ?? 0
        if !UserDefaults.standard.bool(forKey: "retroReimportV5") {
            if importRetroCSV(context) {
                UserDefaults.standard.set(true, forKey: "retroReimportV5")
                forcedRetro = true
                DebugLog.shared.add("seed: retro force-reimported")
            }
        } else if cellCount == 0, importRetroCSV(context) {
            DebugLog.shared.add("seed: retro imported")
        }
        // Manual biomarkers (flag-guarded inside).
        if BiomarkerSeeder.seedIfNeeded(context: context) {
            DebugLog.shared.add("seed: biomarkers imported")
        }
        // Workout blocks — seed when none exist.
        let workoutCount = (try? context.fetchCount(FetchDescriptor<WorkoutBlock>())) ?? 0
        if workoutCount == 0 {
            for (i, b) in WorkoutSeed.blocks.enumerated() {
                context.insert(WorkoutBlock(title: b.0, content: b.1, order: i))
            }
            try? context.save()
            DebugLog.shared.add("seed: workout imported")
        }
        let dm = (try? context.fetchCount(FetchDescriptor<DailyMetric>())) ?? 0
        let rc = (try? context.fetchCount(FetchDescriptor<RetroCell>())) ?? 0
        let wb = (try? context.fetchCount(FetchDescriptor<WorkoutBlock>())) ?? 0
        DebugLog.shared.add("bootstrap: dailyMetrics=\(dm) retroCells=\(rc) workouts=\(wb)")
        return forcedRetro
    }

    /// Wipes and reseeds the retro matrix from the bundled CSV.
    @MainActor
    static func importRetroCSV(_ context: ModelContext) -> Bool {
        guard let url = Bundle.main.url(forResource: "RetroSeed", withExtension: "csv") else {
            DebugLog.shared.add("retro: RetroSeed.csv NOT in bundle"); return false
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            DebugLog.shared.add("retro: could not read csv"); return false
        }
        let records = RetroImportView.parseDelimited(text, delimiter: ",")
        DebugLog.shared.add("retro: csv chars=\(text.count) records=\(records.count)")
        guard records.count >= 2, let header = records.first else {
            DebugLog.shared.add("retro: too few records"); return false
        }

        try? context.delete(model: RetroCell.self)
        try? context.delete(model: RetroRow.self)
        try? context.delete(model: RetroColumn.self)
        try? context.save()

        var colByIndex: [Int: RetroColumn] = [:]
        for idx in 1..<header.count {
            let label = header[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let col = RetroColumn(label: label, order: idx - 1)
            context.insert(col); colByIndex[idx] = col
        }
        var order = 0, cellCount = 0
        for record in records.dropFirst() {
            guard let name = record.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let row = RetroRow(name: name, order: order); order += 1
            context.insert(row)
            for idx in 1..<record.count {
                guard let col = colByIndex[idx] else { continue }
                let value = record[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value != "-" else { continue }
                context.insert(RetroCell(rowId: row.id, colId: col.id, text: value))
                cellCount += 1
            }
        }
        do {
            try context.save()
            DebugLog.shared.add("retro: inserted rows=\(order) cells=\(cellCount)")
        } catch {
            DebugLog.shared.add("retro: SAVE ERROR \(error)")
            return false
        }
        return true
    }
}
