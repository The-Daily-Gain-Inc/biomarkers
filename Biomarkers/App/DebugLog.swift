import Foundation

/// In-memory diagnostics ring buffer, shown in Settings so failures on
/// device are visible without a debugger attached.
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published var lines: [String] = []

    private let fileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("debug.log")

    func add(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        lines.append("\(stamp)  \(message)")
        if lines.count > 120 { lines.removeFirst(lines.count - 120) }
        try? joined.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    var joined: String { lines.joined(separator: "\n") }

    /// Callable from any isolation context (e.g. GarminOAuth); hops to main.
    nonisolated static func note(_ message: String) {
        Task { @MainActor in shared.add(message) }
    }

    /// One-shot inspection of the captured token so we know what kind of
    /// credential the web app actually stores (and whether it's a JWT the
    /// API gateway would accept).
    func diagnoseToken(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            add("token diag: not JSON, len=\(json.count) head=\(json.prefix(40))")
            return
        }
        add("token diag: keys=[\(obj.keys.sorted().joined(separator: ","))]")
        let access = (obj["access_token"] as? String) ?? ""
        add("token diag: access_len=\(access.count) type=\(obj["token_type"] as? String ?? "?")")
        let segs = access.split(separator: ".")
        if segs.count == 3 {
            var b64 = String(segs[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            if let payloadData = Data(base64Encoded: b64),
               let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                add("token diag JWT: iss=\(payload["iss"] ?? "?") aud=\(payload["aud"] ?? "?") scope=\(payload["scope"] ?? payload["scp"] ?? "?")")
            }
        } else {
            add("token diag: access_token is not a JWT (\(segs.count) segments)")
        }
    }
}
