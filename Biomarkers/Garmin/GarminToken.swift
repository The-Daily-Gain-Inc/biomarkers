import Foundation

/// OAuth2 bearer token as the Garmin Connect web app stores it in
/// localStorage under the key "token". Parsed defensively: only
/// access_token is required, everything else is optional.
struct GarminToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?
    var capturedAt: Date

    var isExpired: Bool {
        guard let expiresIn else { return false }
        return Date() > capturedAt.addingTimeInterval(expiresIn - 60)
    }

    /// Parses the raw localStorage JSON string. Returns nil if no
    /// access_token can be found.
    static func parse(localStorageJSON: String) -> GarminToken? {
        guard let data = localStorageJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty
        else { return nil }
        return GarminToken(
            accessToken: access,
            refreshToken: obj["refresh_token"] as? String,
            expiresIn: (obj["expires_in"] as? NSNumber)?.doubleValue,
            capturedAt: Date()
        )
    }
}
