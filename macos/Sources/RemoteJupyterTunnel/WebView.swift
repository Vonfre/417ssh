import SwiftUI
import WebKit

struct WebWorkspaceBrowserView: NSViewRepresentable {
    let url: URL?
    let reloadToken: Int
    let onLoadComplete: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoadComplete = onLoadComplete

        guard let url else { return }

        let shouldReload = context.coordinator.lastURL != url
            || context.coordinator.lastReloadToken != reloadToken

        guard shouldReload else { return }

        context.coordinator.lastURL = url
        context.coordinator.lastReloadToken = reloadToken
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadComplete: onLoadComplete)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastURL: URL?
        var lastReloadToken = 0
        var onLoadComplete: () -> Void

        init(onLoadComplete: @escaping () -> Void) {
            self.onLoadComplete = onLoadComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadComplete()
        }
    }
}
