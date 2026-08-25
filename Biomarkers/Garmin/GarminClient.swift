import Foundation

enum GarminError: Error {
    case needsLogin
    case http(Int)
    case badResponse
}

struct GarminActivitySummary: Decodable {
    struct TypeRef: Decodable { let typeKey: String? }
    let activityId: Int
    let activityName: String?
    let startTimeLocal: String?
    let duration: Double?
    let calories: Double?
    let activityTrainingLoad: Double?
    let activityType: TypeRef?

    var startDate: Date? {
        guard let startTimeLocal else { return nil }
        return GarminClient.localDateFormatter.date(from: startTimeLocal)
    }
}

struct GarminZoneTime: Decodable {
    let zoneNumber: Int?
    let secsInZone: Double?
    let zoneLowBoundary: Int?
}

/// Calls Garmin Connect's internal (unofficial) web endpoints, mimicking the
/// web app: bearer token from the webview session + DI-Backend header.
/// These endpoints change without notice — parsing is defensive and raw JSON
/// is cached upstream so breakage never loses data.
@MainActor
final class GarminClient {
    private let session: SessionStore

    nonisolated(unsafe) static let localDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    init(session: SessionStore) {
        self.session = session
    }

    func activityList(start: Int, limit: Int) async throws -> (summaries: [GarminActivitySummary], raw: Data) {
        let data = try await get(path: "/activitylist-service/activities/search/activities?limit=\(limit)&start=\(start)")
        let summaries = try JSONDecoder().decode([GarminActivitySummary].self, from: data)
        return (summaries, data)
    }

    func hrTimeInZones(activityId: Int) async throws -> (zones: [GarminZoneTime], raw: Data) {
        let data = try await get(path: "/activity-service/activity/\(activityId)/hrTimeInZones")
        let zones = try JSONDecoder().decode([GarminZoneTime].self, from: data)
        return (zones, data)
    }

    /// The user's HR zone lower boundaries (bpm), taken from the most recent
    /// activity that has zone data. Returns 5 ascending bpm floors for Z1…Z5.
    func hrZoneBoundaries() async throws -> [Int]? {
        let (summaries, _) = try await activityList(start: 0, limit: 20)
        for summary in summaries {
            guard let (zones, _) = try? await hrTimeInZones(activityId: summary.activityId) else { continue }
            let floors = zones
                .sorted { ($0.zoneNumber ?? 0) < ($1.zoneNumber ?? 0) }
                .compactMap { $0.zoneLowBoundary }
            if floors.count >= 5 { return Array(floors.prefix(5)) }
        }
        return nil
    }

    // MARK: - Wellness / metrics (dashboard)
    // All parsed via JSONSerialization with defensive key digging — these
    // internal endpoints drift, and a missing key should degrade to "—",
    // not crash the dashboard.

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    func json(path: String) async throws -> Any {
        let data = try await get(path: path)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// usersummary: steps, resting HR, stress, total calories for one day.
    func dailySummary(date: Date) async throws -> [String: Any] {
        let day = Self.dayFormatter.string(from: date)
        return try await json(path: "/usersummary-service/usersummary/daily?calendarDate=\(day)") as? [String: Any] ?? [:]
    }

    /// HRV nightly averages for a date range.
    func hrvDaily(start: Date, end: Date) async throws -> [[String: Any]] {
        let s = Self.dayFormatter.string(from: start), e = Self.dayFormatter.string(from: end)
        let obj = try await json(path: "/hrv-service/hrv/daily/\(s)/\(e)") as? [String: Any]
        return obj?["hrvSummaries"] as? [[String: Any]] ?? []
    }

    /// VO2 max daily values for a date range.
    func vo2maxDaily(start: Date, end: Date) async throws -> [[String: Any]] {
        let s = Self.dayFormatter.string(from: start), e = Self.dayFormatter.string(from: end)
        return try await json(path: "/metrics-service/metrics/maxmet/daily/\(s)/\(e)") as? [[String: Any]] ?? []
    }

    func fitnessAge(date: Date) async throws -> [String: Any] {
        let day = Self.dayFormatter.string(from: date)
        return try await json(path: "/fitnessage-service/fitnessage/\(day)") as? [String: Any] ?? [:]
    }

    private func get(path: String, refreshed: Bool = false) async throws -> Data {
        guard let current = session.token else { throw GarminError.needsLogin }

        // connectapi.garmin.com accepts the OAuth2 bearer directly with a
        // Garmin mobile User-Agent — the host the garth/garminconnect
        // libraries use. It is NOT behind the web bot-wall that guards
        // connect.garmin.com, so plain URLSession works here.
        let (status, data) = try await perform(host: "connectapi.garmin.com", path: path,
                                               token: current.accessToken)
        DebugLog.shared.add("connectapi \(status) \(path.prefix(55))")
        if (200...299).contains(status) { return data }

        if [401, 403].contains(status), !refreshed {
            // Bearer stale — re-mint from the webview session and retry once.
            if await session.refreshSilently() {
                return try await get(path: path, refreshed: true)
            }
            session.needsLogin = true
            throw GarminError.needsLogin
        }
        if [401, 403].contains(status) {
            session.needsLogin = true
            throw GarminError.needsLogin
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        DebugLog.shared.add("connectapi \(status) body=\(body.prefix(80))")
        throw GarminError.http(status)
    }

    private func perform(host: String, path: String, token: String) async throws -> (Int, Data) {
        guard let url = URL(string: "https://\(host)" + path) else { throw GarminError.badResponse }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Garmin Connect Mobile UA — connectapi expects a mobile client,
        // not a browser; a Safari UA is what triggers the 401 wall.
        req.setValue("GCM-iOS-5.7.2.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GarminError.badResponse }
        return (http.statusCode, data)
    }
}
