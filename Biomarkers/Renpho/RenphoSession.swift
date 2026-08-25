import Foundation

/// Renpho cloud session (unofficial qnclouds API). Signs in with the user's
/// Renpho email + RSA-encrypted password, stores the session key and user id.
@MainActor
final class RenphoSession: ObservableObject {
    @Published var isConnected = false
    @Published var lastError: String?

    private static let keychainKey = "renpho.session"

    struct Creds: Codable, Equatable {
        var email: String
        var sessionKey: String
        var userId: Int
    }
    @Published private(set) var creds: Creds?

    init() {
        if let data = Keychain.load(key: Self.keychainKey),
           let c = try? JSONDecoder().decode(Creds.self, from: data) {
            creds = c
            isConnected = true
        }
    }

    func login(email: String, password: String) async {
        lastError = nil
        guard let encrypted = RenphoCrypto.encryptPassword(password) else {
            lastError = "Could not encrypt password."
            return
        }
        var req = URLRequest(url: URL(string: "https://renpho.qnclouds.com/api/v3/users/sign_in.json?app_id=Renpho")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "secure_flag": 1,
            "email": email,
            "password": encrypted,
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = "Renpho sign-in failed (HTTP \(status))."
                return
            }
            guard let key = obj["terminal_user_session_key"] as? String else {
                let msg = (obj["status_message"] as? String) ?? "check email/password"
                lastError = "Renpho sign-in failed: \(msg)"
                return
            }
            let uid = (obj["id"] as? NSNumber)?.intValue
                ?? (obj["user_id"] as? NSNumber)?.intValue
                ?? Int((obj["id"] as? String) ?? "") ?? 0
            let c = Creds(email: email, sessionKey: key, userId: uid)
            creds = c
            isConnected = true
            if let enc = try? JSONEncoder().encode(c) { Keychain.save(enc, key: Self.keychainKey) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        creds = nil
        isConnected = false
        lastError = nil
        Keychain.delete(key: Self.keychainKey)
    }
}
