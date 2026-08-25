import Foundation
import WebKit

/// Holds the Garmin bearer token and knows how to silently re-mint it from
/// the persisted webview session (cookies survive in the default
/// WKWebsiteDataStore, so a hidden page load of connect.garmin.com usually
/// SSO-redirects straight back with a fresh token in localStorage).
@MainActor
final class SessionStore: ObservableObject {
    @Published var token: GarminToken?
    @Published var needsLogin = false

    private static let keychainKey = "garmin.token"
    private var refresher: HiddenTokenRefresher?

    init() {
        if let data = Keychain.load(key: Self.keychainKey) {
            token = try? JSONDecoder().decode(GarminToken.self, from: data)
        }
    }

    var isLoggedIn: Bool { token != nil }

    func store(localStorageJSON: String) -> Bool {
        guard let parsed = GarminToken.parse(localStorageJSON: localStorageJSON) else { return false }
        token = parsed
        needsLogin = false
        if let data = try? JSONEncoder().encode(parsed) {
            Keychain.save(data, key: Self.keychainKey)
        }
        return true
    }

    /// Tries to refresh the token without user interaction. Returns true on success.
    func refreshSilently() async -> Bool {
        let refresher = HiddenTokenRefresher()
        self.refresher = refresher
        defer { self.refresher = nil }
        guard let json = await refresher.fetchTokenJSON() else {
            needsLogin = true
            return false
        }
        return store(localStorageJSON: json)
    }

    func logout() {
        token = nil
        Keychain.delete(key: Self.keychainKey)
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast) {}
    }
}

/// Off-screen webview that loads connect.garmin.com and pulls the OAuth
/// token out of localStorage. Fails (returns nil) if the session cookies
/// have expired and Garmin bounces to the SSO sign-in page.
@MainActor
final class HiddenTokenRefresher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var attempts = 0

    func fetchTokenJSON() async -> String? {
        await withCheckedContinuation { cont in
            continuation = cont
            let wv = WKWebView(frame: .zero)
            wv.navigationDelegate = self
            webView = wv
            wv.load(URLRequest(url: URL(string: "https://connect.garmin.com/modern/")!))
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                self?.finish(nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tryExtract(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func tryExtract(from webView: WKWebView) {
        guard let host = webView.url?.host, host.contains("connect.garmin.com"),
              webView.url?.path.contains("signin") != true
        else {
            // Landed on SSO — the session is dead; interactive login required.
            if webView.url?.host?.contains("sso") == true { finish(nil) }
            return
        }
        webView.evaluateJavaScript("window.localStorage.getItem('token')") { [weak self] result, _ in
            guard let self else { return }
            if let json = result as? String, !json.isEmpty {
                self.finish(json)
            } else if self.attempts < 5 {
                // The SPA may write the token shortly after load; retry briefly.
                self.attempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
                    guard let webView else { return }
                    self?.tryExtract(from: webView)
                }
            } else {
                self.finish(nil)
            }
        }
    }

    private func finish(_ json: String?) {
        continuation?.resume(returning: json)
        continuation = nil
        webView?.navigationDelegate = nil
        webView = nil
    }
}
