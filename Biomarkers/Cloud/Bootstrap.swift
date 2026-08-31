import Foundation
import SwiftData

/// Seeds the bundled historical data at launch — but only for collections the
/// account is genuinely missing. The gating decision (restore completed AND the
/// cloud collection was confirmed empty AND the per-account flag is unset) is
/// made by CloudSync.seed(); this type just performs the imports it's told to.
///
/// All seed ids are DETERMINISTIC (derived from label/name/title), so a re-run
/// upserts in place and can never duplicate the matrix cloud-wide.
enum Bootstrap {
    struct Result {
        var seededRetro = false
        var seededBiomarkers = false
        var seededWorkouts = false
    }

    @MainActor
    @discardableResult
    static func run(context: ModelContext,
                    seedRetro: Bool,
                    seedBiomarkers: Bool,
                    seedWorkouts: Bool) -> Result {
        var result = Result()

        if seedRetro, importRetroCSV(context) {
            result.seededRetro = true
            DebugLog.shared.add("seed: retro imported")
        }
        if seedBiomarkers, BiomarkerSeeder.seed(context: context) {
            result.seededBiomarkers = true
            DebugLog.shared.add("seed: biomarkers imported")
        }
        if seedWorkouts {
            for (i, b) in WorkoutSeed.blocks.enumerated() {
                let id = WorkoutBlock.seedId(title: b.0)
                context.insert(WorkoutBlock(id: id, title: b.0, content: b.1, order: i))
            }
            try? context.save()
            result.seededWorkouts = true
            DebugLog.shared.add("seed: workout imported")
        }

        let dm = (try? context.fetchCount(FetchDescriptor<DailyMetric>())) ?? 0
        let rc = (try? context.fetchCount(FetchDescriptor<RetroCell>())) ?? 0
        let wb = (try? context.fetchCount(FetchDescriptor<WorkoutBlock>())) ?? 0
        DebugLog.shared.add("bootstrap: dailyMetrics=\(dm) retroCells=\(rc) workouts=\(wb)")
        return result
    }

    /// Imports the bundled retro CSV using deterministic ids, upserting in place
    /// (no wipe) so a re-run is idempotent and never duplicates or clobbers.
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

        let existingCols = Dictionary((try? context.fetch(FetchDescriptor<RetroColumn>()))?.map { ($0.id, $0) } ?? [],
                                      uniquingKeysWith: { a, _ in a })
        let existingRows = Dictionary((try? context.fetch(FetchDescriptor<RetroRow>()))?.map { ($0.id, $0) } ?? [],
                                      uniquingKeysWith: { a, _ in a })
        let existingCells = Set((try? context.fetch(FetchDescriptor<RetroCell>()))?.map { $0.id } ?? [])

        var colByIndex: [Int: RetroColumn] = [:]
        for idx in 1..<header.count {
            let label = header[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let id = RetroColumn.seedId(label: label)
            if let col = existingCols[id] { colByIndex[idx] = col }
            else {
                let col = RetroColumn(id: id, label: label, order: idx - 1)
                context.insert(col); colByIndex[idx] = col
            }
        }
        var order = 0, cellCount = 0
        for record in records.dropFirst() {
            guard let name = record.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let rowId = RetroRow.seedId(name: name)
            let row = existingRows[rowId] ?? RetroRow(id: rowId, name: name, order: order)
            if existingRows[rowId] == nil { context.insert(row) }
            order += 1
            for idx in 1..<record.count {
                guard let col = colByIndex[idx] else { continue }
                let value = record[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value != "-" else { continue }
                let cellId = RetroCell.makeId(rowId: row.id, colId: col.id)
                if !existingCells.contains(cellId) {
                    context.insert(RetroCell(rowId: row.id, colId: col.id, text: value))
                    cellCount += 1
                }
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
