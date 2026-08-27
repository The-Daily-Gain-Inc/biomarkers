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

    /// Raw HR time series for an activity: (bpm, elapsedSeconds) pairs, parsed
    /// from the activity details endpoint. Nil samples (no HR) are skipped.
    func hrSeries(activityId: Int) async throws -> (bpm: [Int], elapsed: [Double]) {
        let obj = try await json(path: "/activity-service/activity/\(activityId)/details?maxChartSize=1200") as? [String: Any]
        guard let descriptors = obj?["metricDescriptors"] as? [[String: Any]],
              let samples = obj?["activityDetailMetrics"] as? [[String: Any]] else { return ([], []) }
        var hrIdx: Int?, timeIdx: Int?
        for d in descriptors {
            let key = (d["key"] as? String ?? "").lowercased()
            let idx = (d["metricsIndex"] as? NSNumber)?.intValue
            if key.contains("heartrate") { hrIdx = idx }
            else if key.contains("elapsedduration") || key.contains("duration") { if timeIdx == nil { timeIdx = idx } }
        }
        guard let hi = hrIdx else { return ([], []) }
        var bpm: [Int] = [], elapsed: [Double] = []
        for s in samples {
            guard let m = s["metrics"] as? [Any] else { continue }
            guard hi < m.count, let hr = (m[hi] as? NSNumber)?.doubleValue, hr > 0 else { continue }
            bpm.append(Int(hr))
            if let ti = timeIdx, ti < m.count, let t = (m[ti] as? NSNumber)?.doubleValue {
                elapsed.append(t)
            } else {
                elapsed.append(Double(bpm.count - 1))
            }
        }
        return (bpm, elapsed)
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

    /// The battery level (0–100) of a Garmin device, if reported.
    func deviceBattery() async throws -> Int? {
        let obj = try await json(path: "/device-service/deviceservice/device-info/all")
        return Self.firstBattery(in: obj)
    }

    private static func firstBattery(in value: Any) -> Int? {
        if let dict = value as? [String: Any] {
            for (k, v) in dict where k.lowercased().contains("battery") {
                if let n = (v as? NSNumber)?.doubleValue, n >= 0, n <= 100 { return Int(n) }
            }
            for v in dict.values { if let b = firstBattery(in: v) { return b } }
        } else if let arr = value as? [Any] {
            for v in arr { if let b = firstBattery(in: v) { return b } }
        }
        return nil
    }

    /// When a Garmin device last uploaded to Connect (true last-sync time).
    func lastDeviceSync() async throws -> Date? {
        let obj = try await json(path: "/device-service/deviceservice/mylastused") as? [String: Any]
        if let ms = (obj?["lastUsedDeviceUploadTime"] as? NSNumber)?.doubleValue, ms > 0 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return nil
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
