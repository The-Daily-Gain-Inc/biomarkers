import Foundation

/// The credential set from Garmin's OAuth handshake. The OAuth2 bearer is
/// what connectapi accepts (short-lived, ~1 day); the OAuth1 token is
/// long-lived and lets us refresh the bearer without another sign-in.
struct GarminToken: Codable, Equatable {
    var accessToken: String          // OAuth2 bearer
    var refreshToken: String?        // OAuth2 refresh (unused; we refresh via OAuth1)
    var expiresIn: Double?
    var capturedAt: Date
    var oauth1Token: String
    var oauth1Secret: String

    var isExpired: Bool {
        guard let expiresIn else { return false }
        return Date() > capturedAt.addingTimeInterval(expiresIn - 120)
    }

    var oauth1: GarminOAuth.OAuth1 { .init(token: oauth1Token, secret: oauth1Secret) }

    init(oauth1: GarminOAuth.OAuth1, oauth2: GarminOAuth.OAuth2) {
        self.accessToken = oauth2.accessToken
        self.refreshToken = oauth2.refreshToken
        self.expiresIn = oauth2.expiresIn
        self.capturedAt = Date()
        self.oauth1Token = oauth1.token
        self.oauth1Secret = oauth1.secret
    }

    mutating func apply(oauth2: GarminOAuth.OAuth2) {
        self.accessToken = oauth2.accessToken
        self.refreshToken = oauth2.refreshToken
        self.expiresIn = oauth2.expiresIn
        self.capturedAt = Date()
    }
}
