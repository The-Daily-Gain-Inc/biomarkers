import Foundation

/// One body-composition measurement from Renpho.
struct RenphoMeasurement {
    let date: Date
    let values: [String: Double]   // keyed by our metric keys (rp_bodyfat, …)
}

@MainActor
final class RenphoClient {
    private let session: RenphoSession

    /// Renpho field name → our DailyMetric key.
    static let fieldMap: [(field: String, key: String)] = [
        ("bodyfat", "rp_bodyfat"),
        ("weight", "rp_weight"),
        ("muscle", "rp_muscle"),
        ("water", "rp_water"),
        ("visfat", "rp_visfat"),
        ("bmi", "rp_bmi"),
        ("bmr", "rp_bmr"),
        ("bone", "rp_bone"),
    ]

    init(session: RenphoSession) {
        self.session = session
    }

    /// Full measurement history, newest last.
    func measurements() async throws -> [RenphoMeasurement] {
        guard let creds = session.creds else { throw URLError(.userAuthenticationRequired) }
        var comps = URLComponents(string: "https://renpho.qnclouds.com/api/v2/measurements/list.json")!
        comps.queryItems = [
            .init(name: "user_id", value: String(creds.userId)),
            .init(name: "last_at", value: "0"),
            .init(name: "locale", value: "en"),
            .init(name: "app_id", value: "Renpho"),
            .init(name: "terminal_user_session_key", value: creds.sessionKey),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["last_ary"] as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }
        let parsed: [RenphoMeasurement] = rows.compactMap { row in
            guard let ts = (row["time_stamp"] as? NSNumber)?.doubleValue else { return nil }
            var values: [String: Double] = [:]
            for (field, key) in Self.fieldMap {
                if let v = (row[field] as? NSNumber)?.doubleValue, v > 0 { values[key] = v }
            }
            guard !values.isEmpty else { return nil }
            return RenphoMeasurement(date: Date(timeIntervalSince1970: ts), values: values)
        }
        return parsed.sorted { $0.date < $1.date }
    }
}
