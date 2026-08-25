import SwiftUI
import WebKit

/// Interactive Garmin SSO sign-in. Loads Garmin's real SSO page (which
/// handles password, CAPTCHA, and MFA), then captures the service ticket
/// (ST-…) that the successful login produces. The ticket is exchanged
/// natively for OAuth tokens — see GarminOAuth.
struct GarminLoginView: UIViewRepresentable {
    let onTicket: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTicket: onTicket) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: GarminOAuth.signinURL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onTicket: (String) -> Void
        private var done = false

        init(onTicket: @escaping (String) -> Void) { self.onTicket = onTicket }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let t = ticket(in: url.absoluteString) {
                capture(t)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done else { return }
            // The ticket usually appears as a redirect to embed?ticket=ST-…,
            // but also lands in the page HTML — scan both.
            if let url = webView.url?.absoluteString, let t = ticket(in: url) {
                capture(t)
                return
            }
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                guard let self, let html = result as? String, let t = self.ticket(in: html) else { return }
                self.capture(t)
            }
        }

        private func ticket(in text: String) -> String? {
            // Match ST-XXXXX-... up to a quote, ampersand, or whitespace.
            guard let range = text.range(of: "ST-[0-9A-Za-z._-]+", options: .regularExpression) else { return nil }
            return String(text[range])
        }

        private func capture(_ ticket: String) {
            guard !done else { return }
            done = true
            DebugLog.shared.add("captured ticket len=\(ticket.count)")
            onTicket(ticket)
        }
    }
}

struct GarminLoginSheet: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var exchanging = false

    var body: some View {
        NavigationStack {
            ZStack {
                GarminLoginView { ticket in
                    exchanging = true
                    Task {
                        let ok = await session.completeLogin(ticket: ticket)
                        exchanging = false
                        if ok { dismiss() }
                    }
                }
                if exchanging {
                    ProgressView {
                        Text("Connecting…")
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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
