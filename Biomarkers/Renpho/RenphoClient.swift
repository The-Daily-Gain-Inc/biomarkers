import Foundation

/// One body-composition measurement from Renpho.
struct RenphoMeasurement {
    let date: Date
    let values: [String: Double]   // keyed by our metric keys (rp_bodyfat, …)
}

enum RenphoRequestError: Error { case auth }

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

    /// Full measurement history, oldest first. Silently re-logs in once if the
    /// stored token has lapsed, so the user never has to re-enter credentials.
    func measurements() async throws -> [RenphoMeasurement] {
        do {
            return try await fetchAll()
        } catch RenphoRequestError.auth {
            guard await session.relogin() else { throw URLError(.userAuthenticationRequired) }
            return try await fetchAll()
        }
    }

    private func fetchAll() async throws -> [RenphoMeasurement] {
        guard let creds = session.creds else { throw URLError(.userAuthenticationRequired) }
        // Measurements are sharded by userId % 24.
        let table = "measurements_info_\(creds.userId % 24)"

        var rows = try await pagedRecords(endpoint: "RenphoHealth/scale/queryBodyCompositionMeasureData",
                                          table: table, creds: creds)
        if rows.isEmpty {
            rows = try await pagedRecords(endpoint: "RenphoHealth/scale/queryAllMeasureDataList",
                                          table: table, creds: creds)
        }

        let parsed: [RenphoMeasurement] = rows.compactMap { row in
            guard let date = timestamp(from: row) else { return nil }
            var values: [String: Double] = [:]
            for (field, key) in Self.fieldMap {
                if let v = (row[field] as? NSNumber)?.doubleValue, v > 0 { values[key] = v }
            }
            guard !values.isEmpty else { return nil }
            return RenphoMeasurement(date: date, values: values)
        }
        return parsed.sorted { $0.date < $1.date }
    }

    private func pagedRecords(endpoint: String, table: String, creds: RenphoSession.Creds) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var page = 1
        let pageSize = 50
        while true {
            let req: [String: Any] = [
                "pageNum": page,
                "pageSize": pageSize,
                "userIds": [String(creds.userId)],
                "tableName": table,
            ]
            guard let body = RenphoCrypto.encryptRequest(req) else { break }
            guard let records = try await post(endpoint: endpoint, body: body, creds: creds), !records.isEmpty else { break }
            out.append(contentsOf: records)
            if records.count < pageSize { break }
            page += 1
            if page > 200 { break }   // safety
        }
        return out
    }

    private func post(endpoint: String, body: [String: String], creds: RenphoSession.Creds) async throws -> [[String: Any]]? {
        var req = URLRequest(url: URL(string: "\(RenphoSession.baseURL)/\(endpoint)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(creds.token, forHTTPHeaderField: "token")
        req.setValue(String(creds.userId), forHTTPHeaderField: "userId")
        req.setValue(RenphoSession.appVersion, forHTTPHeaderField: "appVersion")
        req.setValue(RenphoSession.platform, forHTTPHeaderField: "platform")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard http == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 401/403 or unparseable → treat as an auth lapse worth a relogin.
            if http == 401 || http == 403 { throw RenphoRequestError.auth }
            return nil
        }
        let code = obj["code"]
        let msg = (obj["msg"] as? String) ?? ""
        guard RenphoSession.isSuccess(code: code, msg: msg) else {
            // A non-success code with data present usually means a stale token.
            DebugLog.shared.add("renpho fetch code=\(code ?? "nil") msg=\(msg)")
            throw RenphoRequestError.auth
        }
        guard let encData = obj["data"] as? String else { return [] }
        let decoded = RenphoCrypto.decryptResponse(encData)
        return Self.extractRecords(decoded) ?? []
    }

    private static func extractRecords(_ page: Any?) -> [[String: Any]]? {
        if let list = page as? [[String: Any]] { return list }
        if let dict = page as? [String: Any] {
            for key in ["list", "data", "records", "measurements"] {
                if let list = dict[key] as? [[String: Any]] { return list }
            }
            if dict["weight"] != nil { return [dict] }
        }
        return nil
    }

    private func timestamp(from row: [String: Any]) -> Date? {
        for key in ["timeStamp", "time_stamp", "createdStamp"] {
            if let n = (row[key] as? NSNumber)?.doubleValue, n > 0 {
                return Date(timeIntervalSince1970: n > 1_000_000_000_000 ? n / 1000 : n)
            }
        }
        return nil
    }
}
