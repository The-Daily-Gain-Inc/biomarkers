import Foundation
import AuthenticationServices

struct OuraToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?
    var capturedAt: Date

    var isExpired: Bool {
        guard let expiresIn else { return false }
        return Date() > capturedAt.addingTimeInterval(expiresIn - 60)
    }
}

/// Oura OAuth2 (authorization code flow) plus personal-token fallback.
/// Redirect URI `biomarkers://oura` must be registered on the Oura app.
@MainActor
final class OuraSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var token: OuraToken?

    private static let keychainKey = "oura.token"
    private static let redirectURI = "biomarkers://oura"
    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        if let data = Keychain.load(key: Self.keychainKey) {
            token = try? JSONDecoder().decode(OuraToken.self, from: data)
        }
    }

    var isConnected: Bool { token != nil }

    func setPersonalToken(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        save(OuraToken(accessToken: trimmed, refreshToken: nil, expiresIn: nil, capturedAt: Date()))
    }

    func disconnect() {
        token = nil
        Keychain.delete(key: Self.keychainKey)
    }

    func startOAuth() {
        var comps = URLComponents(string: "https://cloud.ouraring.com/oauth/authorize")!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Config.ouraClientId),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: "daily heartrate workout personal"),
        ]
        let session = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: "biomarkers") { [weak self] url, _ in
            guard let self, let url,
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "code" })?.value
            else { return }
            Task { await self.exchange(code: code) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    private func exchange(code: String) async {
        await tokenRequest(body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Config.ouraClientId,
            "client_secret": Secrets.ouraClientSecret,
        ])
    }

    /// Refreshes if possible; returns true when a usable token exists after the call.
    func refreshIfNeeded() async -> Bool {
        guard let token else { return false }
        guard token.isExpired, let refresh = token.refreshToken else { return true }
        await tokenRequest(body: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": Config.ouraClientId,
            "client_secret": Secrets.ouraClientSecret,
        ])
        return self.token != nil
    }

    private func tokenRequest(body: [String: String]) async {
        var req = URLRequest(url: URL(string: "https://api.ouraring.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else { return }
        save(OuraToken(
            accessToken: access,
            refreshToken: obj["refresh_token"] as? String,
            expiresIn: (obj["expires_in"] as? NSNumber)?.doubleValue,
            capturedAt: Date()
        ))
    }

    private func save(_ token: OuraToken) {
        self.token = token
        if let data = try? JSONEncoder().encode(token) {
            Keychain.save(data, key: Self.keychainKey)
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { ASPresentationAnchor() }
    }
}
