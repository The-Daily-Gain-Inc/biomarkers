import Foundation
import SwiftData

/// A free-text note attached to one day of logged data ("fasted", "sick",
/// "new BP cuff"). One per day; empty text means the note was cleared.
@Model
final class DailyNote {
    @Attribute(.unique) var id: String
    var day: Date
    var text: String
    /// Last local edit — last-writer-wins on restore.
    var updatedAt: Date = Date()

    init(day: Date, text: String) {
        let start = Calendar.current.startOfDay(for: day)
        self.day = start
        self.text = text
        self.id = DailyNote.makeId(day: start)
    }

    static func makeId(day: Date) -> String {
        "note#\(Int(Calendar.current.startOfDay(for: day).timeIntervalSince1970))"
    }

    func touch() { updatedAt = Date() }
}
