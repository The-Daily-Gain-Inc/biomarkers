import Foundation
import CryptoKit

/// Garmin's real auth handshake, ported from the garth library.
///
/// The web session token is minted for Garmin's web frontend and the API
/// gateway (connectapi.garmin.com) rejects it. The mobile apps instead:
///   1. complete SSO to obtain a service ticket (ST-…),
///   2. GET oauth-service/preauthorized (OAuth1-signed) → OAuth1 token,
///   3. POST oauth-service/exchange (OAuth1-signed) → OAuth2 bearer.
/// That OAuth2 bearer is what connectapi accepts. The OAuth1 token is
/// long-lived, so refreshing the OAuth2 bearer never needs the webview.
enum GarminOAuth {
    // Public consumer credentials the Garmin mobile clients use (same ones
    // garth ships). Fetched fresh from garth's S3 mirror when reachable, so
    // we track rotations; these are the fallback.
    private static let fallbackKey = "fc3e99d2-118c-44b8-8ae3-03370dde24c0"
    private static let fallbackSecret = "E08WAR897WEy2knn7aFBrvegVAf0AFdWBBF"
    private static let userAgent = "GCM-iOS-5.7.2.1"

    struct OAuth1 { let token: String; let secret: String }
    struct OAuth2 {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
    }

    private static func consumer() async -> (key: String, secret: String) {
        guard let url = URL(string: "https://thegarth.s3.amazonaws.com/oauth_consumer.json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let k = obj["consumer_key"] as? String,
              let s = obj["consumer_secret"] as? String
        else { return (fallbackKey, fallbackSecret) }
        return (k, s)
    }

    static let ssoEmbed = "https://sso.garmin.com/sso/embed"

    /// The SSO sign-in URL to load in the webview.
    static var signinURL: URL {
        var comps = URLComponents(string: "https://sso.garmin.com/sso/signin")!
        comps.queryItems = [
            .init(name: "id", value: "gauth-widget"),
            .init(name: "embedWidget", value: "true"),
            .init(name: "gauthHost", value: ssoEmbed),
            .init(name: "service", value: ssoEmbed),
            .init(name: "source", value: ssoEmbed),
            .init(name: "redirectAfterAccountLoginUrl", value: ssoEmbed),
            .init(name: "redirectAfterAccountCreationUrl", value: ssoEmbed),
        ]
        return comps.url!
    }

    // MARK: - Handshake

    /// ticket → OAuth1 token → OAuth2 bearer.
    static func exchange(ticket: String) async throws -> (OAuth1, OAuth2) {
        let c = await consumer()
        let oauth1 = try await preauthorized(ticket: ticket, consumer: c)
        let oauth2 = try await exchangeOAuth2(oauth1: oauth1, consumer: c)
        return (oauth1, oauth2)
    }

    /// Refresh the short-lived OAuth2 bearer from a stored OAuth1 token —
    /// no webview needed.
    static func refresh(oauth1: OAuth1) async throws -> OAuth2 {
        let c = await consumer()
        return try await exchangeOAuth2(oauth1: oauth1, consumer: c)
    }

    private static func preauthorized(ticket: String, consumer: (key: String, secret: String)) async throws -> OAuth1 {
        let base = "https://connectapi.garmin.com/oauth-service/oauth/preauthorized"
        let query = [
            "ticket": ticket,
            "login-url": ssoEmbed,
            "accepts-mfa-tokens": "true",
        ]
        var comps = URLComponents(string: base)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(oauth1Header(method: "GET", url: base, queryParams: query,
                                  consumer: consumer, token: nil, tokenSecret: ""),
                     forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        guard status == 200 else {
            DebugLog.note("preauthorized \(status): \(body.prefix(120))")
            throw GarminError.http(status)
        }
        let parsed = formDecode(body)
        guard let token = parsed["oauth_token"], let secret = parsed["oauth_token_secret"] else {
            DebugLog.note("preauthorized: missing oauth_token in \(body.prefix(120))")
            throw GarminError.badResponse
        }
        DebugLog.note("preauthorized OK (oauth1 len=\(token.count))")
        return OAuth1(token: token, secret: secret)
    }

    private static func exchangeOAuth2(oauth1: OAuth1, consumer: (key: String, secret: String)) async throws -> OAuth2 {
        let url = "https://connectapi.garmin.com/oauth-service/oauth/exchange/user/2.0"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(oauth1Header(method: "POST", url: url, queryParams: [:],
                                  consumer: consumer, token: oauth1.token, tokenSecret: oauth1.secret),
                     forHTTPHeaderField: "Authorization")
        req.httpBody = Data()

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        guard status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            DebugLog.note("exchange \(status): \(body.prefix(120))")
            throw GarminError.http(status)
        }
        DebugLog.note("exchange OK (oauth2 len=\(access.count))")
        return OAuth2(
            accessToken: access,
            refreshToken: obj["refresh_token"] as? String,
            expiresIn: (obj["expires_in"] as? NSNumber)?.doubleValue
        )
    }

    // MARK: - OAuth1 signing (HMAC-SHA1)

    private static func oauth1Header(method: String, url: String, queryParams: [String: String],
                                     consumer: (key: String, secret: String),
                                     token: String?, tokenSecret: String) -> String {
        var oauth: [String: String] = [
            "oauth_consumer_key": consumer.key,
            "oauth_nonce": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": String(Int(Date().timeIntervalSince1970)),
            "oauth_version": "1.0",
        ]
        if let token { oauth["oauth_token"] = token }

        // Signature base string uses oauth params + query params, sorted.
        var allParams = oauth
        for (k, v) in queryParams { allParams[k] = v }
        let encoded: [(String, String)] = allParams.map { (pct($0.key), pct($0.value)) }
        let sortedPairs = encoded.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        let paramString = sortedPairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        let base = "\(method.uppercased())&\(pct(url))&\(pct(paramString))"
        let signingKey = "\(pct(consumer.secret))&\(pct(tokenSecret))"
        let signature = hmacSHA1(base, key: signingKey)
        oauth["oauth_signature"] = signature

        let header = oauth
            .sorted { $0.key < $1.key }
            .map { "\(pct($0.key))=\"\(pct($0.value))\"" }
            .joined(separator: ", ")
        return "OAuth \(header)"
    }

    private static func hmacSHA1(_ message: String, key: String) -> String {
        let keyData = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(message.utf8), using: keyData)
        return Data(mac).base64EncodedString()
    }

    /// RFC3986 percent-encoding (unreserved: ALPHA DIGIT - . _ ~).
    private static func pct(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func formDecode(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }
        return out
    }
}
