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
    init(id: String = UUID().uuidString, name: String, order: Int) {
        self.id = id
        self.name = name
        self.order = order
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
    static let columns: [String] = [
        "Continue doing", "Stop doing", "Plan doing - May 21", "Updates to Plan - June 30",
        "Score / 3 - June 30", "Updates - Aug 2nd", "Updates - Aug 30th", "Updates - Sep 28th",
        "October 5", "October 12", "October 18", "October 26", "November 2", "November 9",
        "November 16", "November 23", "November 29", "December 6", "December 13", "December 19",
        "December 25", "December 31", "January 6", "January 17", "January 23", "January 31",
        "February 6", "February 14", "February 21", "February 28", "March 14", "March 21",
        "March 28", "April 4", "April 11", "April 25", "May 2", "May 9", "May 16", "May 23",
        "May 30", "June 6", "June 13", "June 19", "June 27", "July 4", "July 11", "July 18",
        "August 8", "August 15", "August 22",
    ]

    static let rows: [String] = [
        "Thoughts", "Exercise", "Nutrition / Food", "Stretching", "Meditation", "Reading",
        "Relationship", "Work Career", "Entrepreneurship", "Skills development", "Leisure / Trips",
        "Biological Family", "Gaming", "Sleep", "Wellbeing / Stress", "Automation", "Social Media",
        "HairCare", "SkinCare", "Refactoring", "Mental Acuity", "Socializing skills",
        "Extracurricular", "Finances", "Idle Time", "Netflix / TV",
    ]

    static let dreams: [(String, String, String)] = [
        ("Financial Independence", "Approved",
         "Have enough money to choose to work and live modest. Do not commit to things that break freedom like cat / car / kids (even home to some extent?). Be able to see my bio family once a year and travel the world with my Naz."),
        ("Front Lever 5s", "Approved",
         "Trained for years and didn't get close. This clearly requires an insane amount of work, nutrition & education. It is also something that I will consider myself really strong if I achieve. I have literally dreamed about this."),
        ("Tech Reference", "Approved",
         "Be a living reference for technology — the person people hand tech problems to and trust the answer, at any point in my life. Stay current enough that I'm never obsolete. Contribute logically to the advancement of domains like education and weddings to make the world better; give advice to people when they need it and always be a trusted reference that provides value."),
    ]

    static let longevityRules: [String] = [
        "Break all UPF (ultra processed foods). In groceries we have bread, oat milk, cereal. Emulsifiers, preservatives, etc. are a no-no.",
        "Eat from 12PM to 8PM so that I can sleep well by 12AM.",
        "Move average steps closer to 8500.",
        "Don't sit all day.",
        "Min 3 workouts per week for strength.",
        "Don't take calcium when unnecessary — audit food using Cronometer.",
        "Microplastics — 0 tolerance.",
    ]
}
