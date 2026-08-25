import Foundation

/// Holds the Garmin OAuth credentials and refreshes the OAuth2 bearer from
/// the stored long-lived OAuth1 token — no webview needed after first login.
@MainActor
final class SessionStore: ObservableObject {
    @Published var token: GarminToken?
    @Published var needsLogin = false
    @Published var loginError: String?

    private static let keychainKey = "garmin.token"

    init() {
        if let data = Keychain.load(key: Self.keychainKey) {
            token = try? JSONDecoder().decode(GarminToken.self, from: data)
        }
    }

    var isLoggedIn: Bool { token != nil }

    /// Completes login from an SSO service ticket via the OAuth handshake.
    func completeLogin(ticket: String) async -> Bool {
        do {
            let (oauth1, oauth2) = try await GarminOAuth.exchange(ticket: ticket)
            let newToken = GarminToken(oauth1: oauth1, oauth2: oauth2)
            token = newToken
            needsLogin = false
            loginError = nil
            persist(newToken)
            DebugLog.shared.add("login complete")
            return true
        } catch {
            loginError = "Garmin sign-in failed: \(error)"
            DebugLog.shared.add("completeLogin failed: \(error)")
            return false
        }
    }

    /// Refreshes the OAuth2 bearer using the stored OAuth1 token.
    func refreshSilently() async -> Bool {
        guard var current = token else { needsLogin = true; return false }
        do {
            let oauth2 = try await GarminOAuth.refresh(oauth1: current.oauth1)
            current.apply(oauth2: oauth2)
            token = current
            persist(current)
            DebugLog.shared.add("refresh complete")
            return true
        } catch {
            DebugLog.shared.add("refresh failed: \(error)")
            needsLogin = true
            return false
        }
    }

    func logout() {
        token = nil
        needsLogin = false
        Keychain.delete(key: Self.keychainKey)
    }

    private func persist(_ token: GarminToken) {
        if let data = try? JSONEncoder().encode(token) {
            Keychain.save(data, key: Self.keychainKey)
        }
    }
}
