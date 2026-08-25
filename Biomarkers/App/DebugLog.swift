import Foundation

/// In-memory diagnostics ring buffer, shown in Settings so failures on
/// device are visible without a debugger attached.
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published var lines: [String] = []

    func add(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        lines.append("\(stamp)  \(message)")
        if lines.count > 120 { lines.removeFirst(lines.count - 120) }
    }

    var joined: String { lines.joined(separator: "\n") }
}
