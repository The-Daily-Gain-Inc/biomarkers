import Foundation
import SwiftData

/// A column in the retro matrix — a review period ("Continue doing",
/// "October 5", …).
@Model
final class RetroColumn {
    @Attribute(.unique) var id: String
    var label: String
    var order: Int
    init(id: String = UUID().uuidString, label: String, order: Int) {
        self.id = id
        self.label = label
        self.order = order
    }
}

/// A row in the retro matrix — a life domain ("Exercise", "Sleep", …).
@Model
final class RetroRow {
    @Attribute(.unique) var id: String
    var name: String
    var order: Int
    /// Excluded sections are hidden from the guided review (still browsable).
    var excluded: Bool = false
    init(id: String = UUID().uuidString, name: String, order: Int, excluded: Bool = false) {
        self.id = id
        self.name = name
        self.order = order
        self.excluded = excluded
    }
}

/// One free-text cell at a (row, column) intersection.
@Model
final class RetroCell {
    @Attribute(.unique) var id: String
    var rowId: String
    var colId: String
    var text: String
    init(rowId: String, colId: String, text: String) {
        self.id = RetroCell.makeId(rowId: rowId, colId: colId)
        self.rowId = rowId
        self.colId = colId
        self.text = text
    }
    static func makeId(rowId: String, colId: String) -> String { "\(rowId)|\(colId)" }
}

/// An editable life dream (Dream / Status / Rationale).
@Model
final class RetroDream {
    @Attribute(.unique) var id: String
    var title: String
    var status: String
    var rationale: String
    var order: Int
    init(id: String = UUID().uuidString, title: String, status: String, rationale: String, order: Int) {
        self.id = id
        self.title = title
        self.status = status
        self.rationale = rationale
        self.order = order
    }
}

/// An editable workout block (e.g. Gym Day, Calisthenics, Skills).
@Model
final class WorkoutBlock {
    @Attribute(.unique) var id: String
    var title: String
    var content: String
    var order: Int
    init(id: String = UUID().uuidString, title: String, content: String, order: Int) {
        self.id = id
        self.title = title
        self.content = content
        self.order = order
    }
}

/// An editable longevity rule.
@Model
final class LongevityRule {
    @Attribute(.unique) var id: String
    var text: String
    var order: Int
    init(id: String = UUID().uuidString, text: String, order: Int) {
        self.id = id
        self.text = text
        self.order = order
    }
}

/// The skeleton to seed on first launch — the user's own domains and the
/// dated review columns, so the grid mirrors their existing sheet.
enum RetroSeed {
    // Neutral starter template only — no personal data. A returning user's
    // real content comes from the cloud (or the on-device cache); a brand-new
    // user starts from this blank template and adds their own.
    static let columns: [String] = ["Continue doing", "Stop doing", "Start doing"]

    static let rows: [String] = [
        "Exercise", "Nutrition", "Sleep", "Work", "Relationships",
        "Finances", "Learning", "Mindfulness",
    ]

    static let dreams: [(String, String, String)] = []
    static let longevityRules: [String] = []

    /// Neutral empty workout — the user's real blocks come from the cloud/seed.
    static let workoutBlocks: [(String, String)] = []
}
