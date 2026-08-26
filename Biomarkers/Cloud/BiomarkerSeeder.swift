import Foundation
import SwiftData

/// One-time import of the bundled historical manual-biomarker CSV into
/// DailyMetric (reading, meditation, porn, glucose, BP, ear age), which then
/// auto-uploads to Firestore. Runs once; the bundle can be removed after.
enum BiomarkerSeeder {
    @MainActor
    static func seedIfNeeded(context: ModelContext) -> Bool {
        if UserDefaults.standard.bool(forKey: "biomarkerSeedV1") { return false }
        guard let url = Bundle.main.url(forResource: "BiomarkerSeed", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            DebugLog.shared.add("seed: BiomarkerSeed.csv missing")
            return false
        }
        let records = RetroImportView.parseDelimited(text, delimiter: ",")
        guard records.count >= 2 else { return false }
        let header = records[0].map { $0.trimmingCharacters(in: .whitespaces) }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current

        var existing = Set<String>()
        if let all = try? context.fetch(FetchDescriptor<DailyMetric>()) { existing = Set(all.map(\.id)) }

        for rec in records.dropFirst() {
            guard let dayStr = rec.first?.trimmingCharacters(in: .whitespaces),
                  let day = df.date(from: dayStr) else { continue }
            for idx in 1..<min(rec.count, header.count) {
                let key = header[idx]
                let raw = rec[idx].trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty, let value = Double(raw) else { continue }
                let id = DailyMetric.makeId(day: day, key: key)
                if !existing.contains(id) {
                    context.insert(DailyMetric(day: day, metricKey: key, value: value))
                    existing.insert(id)
                }
            }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: "biomarkerSeedV1")
        DebugLog.shared.add("seed: biomarkers rows=\(records.count - 1)")
        return true
    }
}
