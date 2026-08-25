import Foundation

struct OuraHeartRateSample: Decodable {
    let bpm: Int
    let timestamp: String

    var date: Date? { OuraClient.isoFormatter.date(from: timestamp) }
}

@MainActor
final class OuraClient {
    private let session: OuraSession

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(session: OuraSession) {
        self.session = session
    }

    /// All-day heart-rate samples in [start, end), following pagination.
    func heartRate(start: Date, end: Date) async throws -> [OuraHeartRateSample] {
        guard await session.refreshIfNeeded(), let token = session.token else {
            throw URLError(.userAuthenticationRequired)
        }
        var samples: [OuraHeartRateSample] = []
        var nextToken: String?
        repeat {
            var comps = URLComponents(string: "https://api.ouraring.com/v2/usercollection/heartrate")!
            comps.queryItems = [
                .init(name: "start_datetime", value: Self.isoFormatter.string(from: start)),
                .init(name: "end_datetime", value: Self.isoFormatter.string(from: end)),
            ]
            if let nextToken { comps.queryItems?.append(.init(name: "next_token", value: nextToken)) }
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            samples.append(contentsOf: page.data)
            nextToken = page.nextToken
        } while nextToken != nil
        return samples
    }

    /// Generic fetch of a daily collection (start_date/end_date, inclusive),
    /// returned as loose dictionaries — Oura fields drift less than Garmin's
    /// but the dashboard degrades to "—" on any missing key.
    func dailyCollection(_ name: String, start: Date, end: Date) async throws -> [[String: Any]] {
        guard await session.refreshIfNeeded(), let token = session.token else {
            throw URLError(.userAuthenticationRequired)
        }
        var rows: [[String: Any]] = []
        var nextToken: String?
        repeat {
            var comps = URLComponents(string: "https://api.ouraring.com/v2/usercollection/\(name)")!
            comps.queryItems = [
                .init(name: "start_date", value: GarminClient.dayFormatter.string(from: start)),
                .init(name: "end_date", value: GarminClient.dayFormatter.string(from: end)),
            ]
            if let nextToken { comps.queryItems?.append(.init(name: "next_token", value: nextToken)) }
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw URLError(.badServerResponse) }
            rows.append(contentsOf: obj["data"] as? [[String: Any]] ?? [])
            nextToken = obj["next_token"] as? String
        } while nextToken != nil
        return rows
    }

    func personalInfo() async throws -> [String: Any] {
        guard await session.refreshIfNeeded(), let token = session.token else {
            throw URLError(.userAuthenticationRequired)
        }
        var req = URLRequest(url: URL(string: "https://api.ouraring.com/v2/usercollection/personal_info")!)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private struct Page: Decodable {
        let data: [OuraHeartRateSample]
        let nextToken: String?
        enum CodingKeys: String, CodingKey {
            case data
            case nextToken = "next_token"
        }
    }
}

/// Buckets a heart-rate time series into 5 zones by %% of max HR
/// (Z1 50–60%% … Z5 90%%+; below 50%% is not counted). Each sample's dwell
/// time is the gap to the next sample, capped at 5 minutes.
func zoneSecondsFromSamples(_ samples: [OuraHeartRateSample], maxHR: Double) -> [Double] {
    var out = [Double](repeating: 0, count: 5)
    let dated = samples.compactMap { s -> (Date, Int)? in
        guard let d = s.date else { return nil }
        return (d, s.bpm)
    }.sorted { $0.0 < $1.0 }
    guard maxHR > 0 else { return out }
    for (i, (date, bpm)) in dated.enumerated() {
        let pct = Double(bpm) / maxHR
        let zone: Int?
        switch pct {
        case ..<0.5: zone = nil
        case ..<0.6: zone = 0
        case ..<0.7: zone = 1
        case ..<0.8: zone = 2
        case ..<0.9: zone = 3
        default: zone = 4
        }
        guard let zone else { continue }
        let dwell: TimeInterval
        if i + 1 < dated.count {
            dwell = min(dated[i + 1].0.timeIntervalSince(date), 300)
        } else {
            dwell = 60
        }
        out[zone] += dwell
    }
    return out
}
