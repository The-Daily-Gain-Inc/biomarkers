import Foundation

/// Renpho Health cloud session (cloud.renpho.com). Logs in with the user's
/// email + password (sent inside the AES-encrypted payload), stores the
/// returned token and user id.
@MainActor
final class RenphoSession: ObservableObject {
    @Published var isConnected = false
    @Published var lastError: String?

    static let baseURL = "https://cloud.renpho.com"
    static let appVersion = "6.6.0"
    static let platform = "android"
    // Body-weight scale device types the login binds against.
    static let scaleTypes = ["01","02","03","04","05","06","07","08","09","0A",
                             "0B","0C","0D","0E","0F","10","11","12","13","14"]

    private static let keychainKey = "renpho.session.v2"

    struct Creds: Codable, Equatable {
        var email: String
        var token: String
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
        let payload: [String: Any] = [
            "questionnaire": [:],
            "login": [
                "password": password,
                "areaCode": "US",
                "appRevision": Self.appVersion,
                "cellphoneType": "Biomarkers-iOS",
                "systemType": "11",
                "email": email,
                "platform": Self.platform,
            ],
            "bindingList": ["deviceTypes": Self.scaleTypes],
        ]
        guard let body = RenphoCrypto.encryptRequest(payload) else {
            lastError = "Could not encrypt the login request."
            return
        }
        do {
            var req = URLRequest(url: URL(string: "\(Self.baseURL)/renpho-aggregation/user/login")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: req)
            let http = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = "Renpho login failed (HTTP \(http))."
                DebugLog.shared.add("renpho login HTTP \(http): \(String(data: data, encoding: .utf8)?.prefix(120) ?? "")")
                return
            }
            let code = obj["code"]
            let msg = (obj["msg"] as? String) ?? ""
            guard RenphoSession.isSuccess(code: code, msg: msg),
                  let encData = obj["data"] as? String,
                  let user = RenphoCrypto.decryptResponse(encData) as? [String: Any],
                  let loginInfo = user["login"] as? [String: Any],
                  let token = loginInfo["token"] as? String else {
                lastError = "Renpho login failed: \(msg.isEmpty ? "check email/password" : msg)"
                DebugLog.shared.add("renpho login code=\(code ?? "nil") msg=\(msg)")
                return
            }
            let uid = (loginInfo["id"] as? NSNumber)?.intValue
                ?? Int((loginInfo["id"] as? String) ?? "") ?? 0
            let c = Creds(email: email, token: token, userId: uid)
            creds = c
            isConnected = true
            if let enc = try? JSONEncoder().encode(c) { Keychain.save(enc, key: Self.keychainKey) }
            DebugLog.shared.add("renpho login OK uid=\(uid)")
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func isSuccess(code: Any?, msg: String) -> Bool {
        if msg.lowercased() == "success" { return true }
        let ok: Set<Int> = [0, 101, 200, 20000]
        if let n = (code as? NSNumber)?.intValue, ok.contains(n) { return true }
        if let s = code as? String, let n = Int(s), ok.contains(n) { return true }
        return false
    }

    func disconnect() {
        creds = nil
        isConnected = false
        lastError = nil
        Keychain.delete(key: Self.keychainKey)
    }
}
