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

    private func get(path: String, isRetry: Bool = false) async throws -> Data {
        guard let token = session.token else { throw GarminError.needsLogin }
        if token.isExpired, !isRetry {
            _ = await session.refreshSilently()
        }
        guard let current = session.token,
              let url = URL(string: "https://connect.garmin.com" + path)
        else { throw GarminError.needsLogin }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("connectapi.garmin.com", forHTTPHeaderField: "DI-Backend")
        req.setValue("NT", forHTTPHeaderField: "NK")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GarminError.badResponse }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            if !isRetry, await session.refreshSilently() {
                return try await get(path: path, isRetry: true)
            }
            session.needsLogin = true
            throw GarminError.needsLogin
        default:
            throw GarminError.http(http.statusCode)
        }
    }
}
