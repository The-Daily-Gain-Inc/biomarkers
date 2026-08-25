import SwiftUI
import WebKit

/// Oura OAuth in a webview: loads the authorize page and intercepts the
/// redirect to thedailygain.ca to capture the authorization code (the page
/// itself never needs to load).
struct OuraLoginView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: OuraSession.authorizeURL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard !done, let url = navigationAction.request.url,
                  url.host?.hasSuffix("thedailygain.ca") == true
            else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value {
                done = true
                onCode(code)
            }
        }
    }
}

struct OuraLoginSheet: View {
    @EnvironmentObject var ouraSession: OuraSession
    @Environment(\.dismiss) private var dismiss
    @State private var exchanging = false

    var body: some View {
        NavigationStack {
            ZStack {
                OuraLoginView { code in
                    exchanging = true
                    Task {
                        await ouraSession.exchange(code: code)
                        dismiss()
                    }
                }
                if exchanging {
                    ProgressView {
                        Text("Connecting…")
                    }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle(Text("Oura Sign In"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
