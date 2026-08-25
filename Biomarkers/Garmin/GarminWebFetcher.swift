import Foundation
import WebKit

/// Executes Garmin Connect API calls as fetch() inside a hidden webview
/// that is logged into connect.garmin.com. This inherits the browser's
/// cookies, user agent, and TLS stack, so requests look exactly like the
/// web app's own — which URLSession calls do not (Garmin's bot protection
/// rejects those with 401/403 even with a valid bearer token).
@MainActor
final class GarminWebFetcher: NSObject, WKNavigationDelegate {
    static let shared = GarminWebFetcher()

    private var webView: WKWebView?
    private var loadContinuations: [CheckedContinuation<Bool, Never>] = []
    private var pageReady = false
    private var loading = false

    /// Ensures the hidden webview has connect.garmin.com loaded with a live
    /// session. Returns false if we ended up on the SSO sign-in page.
    func prepare(forceReload: Bool = false) async -> Bool {
        if pageReady, !forceReload, webView != nil { return true }
        let wv: WKWebView
        if let existing = webView {
            wv = existing
        } else {
            wv = WKWebView(frame: .zero)
            wv.navigationDelegate = self
            webView = wv
        }
        pageReady = false
        if !loading {
            loading = true
            wv.load(URLRequest(url: URL(string: "https://connect.garmin.com/modern/")!))
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                self?.finishLoad(success: false, timedOut: true)
            }
        }
        return await withCheckedContinuation { cont in
            loadContinuations.append(cont)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard loading else { return }
        if let host = webView.url?.host, host.contains("connect.garmin.com"),
           webView.url?.path.contains("signin") != true {
            finishLoad(success: true)
        } else if webView.url?.host?.contains("sso") == true {
            finishLoad(success: false)
        }
        // Intermediate redirects: keep waiting for the final page.
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(success: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(success: false)
    }

    private func finishLoad(success: Bool, timedOut: Bool = false) {
        guard loading else { return }
        if timedOut && pageReady { return }
        loading = false
        pageReady = success
        let conts = loadContinuations
        loadContinuations = []
        conts.forEach { $0.resume(returning: success) }
    }

    /// GET the given API path from within the page. Throws needsLogin when
    /// the session is dead, .http otherwise.
    func fetch(path: String, isRetry: Bool = false) async throws -> Data {
        guard await prepare() else {
            DebugLog.shared.add("webfetch: no session (SSO redirect)")
            throw GarminError.needsLogin
        }
        guard let wv = webView else { throw GarminError.badResponse }
        let js = """
        const token = JSON.parse(window.localStorage.getItem('token') || '{}');
        const resp = await fetch('https://connect.garmin.com' + path, {
            headers: {
                'Authorization': 'Bearer ' + (token.access_token || ''),
                'DI-Backend': 'connectapi.garmin.com',
                'NK': 'NT',
                'Accept': 'application/json'
            },
            credentials: 'include'
        });
        const body = await resp.text();
        return { status: resp.status, body: body };
        """
        let result: Any?
        do {
            result = try await wv.callAsyncJavaScript(js, arguments: ["path": path], contentWorld: .page)
        } catch {
            DebugLog.shared.add("webfetch JS error \(path): \(error.localizedDescription)")
            throw GarminError.badResponse
        }
        guard let dict = result as? [String: Any],
              let status = (dict["status"] as? NSNumber)?.intValue,
              let body = dict["body"] as? String
        else { throw GarminError.badResponse }

        DebugLog.shared.add("webfetch \(status) \(path.prefix(60))")
        switch status {
        case 200...299:
            return Data(body.utf8)
        case 401, 403:
            if !isRetry {
                // Session token stale — reload the page so the SPA re-mints
                // it from cookies, then retry once.
                _ = await prepare(forceReload: true)
                return try await fetch(path: path, isRetry: true)
            }
            throw GarminError.needsLogin
        default:
            throw GarminError.http(status)
        }
    }

    func reset() {
        pageReady = false
        webView?.navigationDelegate = nil
        webView = nil
    }
}
