import Foundation

struct OuraToken: Codable, Equatable {
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
/// The redirect URI registered on the Oura application is thedailygain.ca;
/// the OuraLoginSheet webview intercepts that redirect to capture the code.
@MainActor
final class OuraSession: ObservableObject {
    @Published var token: OuraToken?
    @Published var lastError: String?

    private static let keychainKey = "oura.token"
    static let redirectURI = "https://thedailygain.ca"

    init() {
        if let data = Keychain.load(key: Self.keychainKey) {
            token = try? JSONDecoder().decode(OuraToken.self, from: data)
        }
    }

    var isConnected: Bool { token != nil }

    static var authorizeURL: URL {
        var comps = URLComponents(string: "https://cloud.ouraring.com/oauth/authorize")!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Config.ouraClientId),
            .init(name: "redirect_uri", value: redirectURI),
        ]
        return comps.url!
    }

    func setPersonalToken(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        save(OuraToken(accessToken: trimmed, refreshToken: nil, expiresIn: nil, capturedAt: Date()))
    }

    func disconnect() {
        token = nil
        lastError = nil
        Keychain.delete(key: Self.keychainKey)
    }

    func exchange(code: String) async {
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
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String
            else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                lastError = "Oura token exchange failed (\(status)): \(bodyText.prefix(200))"
                return
            }
            lastError = nil
            save(OuraToken(
                accessToken: access,
                refreshToken: obj["refresh_token"] as? String,
                expiresIn: (obj["expires_in"] as? NSNumber)?.doubleValue,
                capturedAt: Date()
            ))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func save(_ token: OuraToken) {
        self.token = token
        if let data = try? JSONEncoder().encode(token) {
            Keychain.save(data, key: Self.keychainKey)
        }
    }
}
