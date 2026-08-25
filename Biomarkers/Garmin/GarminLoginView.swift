import SwiftUI
import WebKit

/// Interactive Garmin Connect sign-in. Shows the real Garmin SSO page in a
/// webview; once the app lands back on connect.garmin.com we lift the OAuth
/// token from localStorage and hand it to the SessionStore.
struct GarminLoginView: UIViewRepresentable {
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: URL(string: "https://connect.garmin.com/signin/")!))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String) -> Void
        private var attempts = 0
        private var done = false

        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            attempts = 0
            tryExtract(from: webView)
        }

        private func tryExtract(from webView: WKWebView) {
            guard !done,
                  let url = webView.url, url.host?.contains("connect.garmin.com") == true,
                  !url.path.contains("signin")
            else { return }
            webView.evaluateJavaScript("window.localStorage.getItem('token')") { [weak self] result, _ in
                guard let self, !self.done else { return }
                if let json = result as? String, !json.isEmpty {
                    self.done = true
                    self.onToken(json)
                } else if self.attempts < 8 {
                    self.attempts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak webView] in
                        guard let webView else { return }
                        self?.tryExtract(from: webView)
                    }
                }
            }
        }
    }
}

struct GarminLoginSheet: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GarminLoginView { json in
                if session.store(localStorageJSON: json) {
                    dismiss()
                }
            }
            .navigationTitle(Text("Garmin Sign In"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
