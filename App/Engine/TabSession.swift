import AppKit
import Observation
import WebKit

/// One tab's live web view. The rest of the app sees plain observable values and a `view: NSView`,
/// never a `WKWebView`.
@MainActor
@Observable
final class TabSession {
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// The web view, as a plain view for the window to host.
    var view: NSView { webView }

    init(configuration: WKWebViewConfiguration = WebViewFactory.configuration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // WebKit posts KVO on the main thread. Every change re-reads all six values; each is only
        // written when it differs, so observers fire for real changes only.
        observations = [
            observe(\.title), observe(\.url), observe(\.isLoading),
            observe(\.estimatedProgress), observe(\.canGoBack), observe(\.canGoForward),
        ]
        sync()
    }

    func load(_ url: URL) {
        if url.isFileURL {
            // A local page may read the files next to it, nothing further.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Runs `functionBody` as the body of an async JavaScript function in the page and returns its
    /// result (`return …`). Values come back as WebKit bridges them: strings, numbers, arrays, dictionaries.
    func callJavaScript(_ functionBody: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(functionBody, arguments: [:], in: nil, contentWorld: .page)
    }

    /// What the page currently shows, rendered by WebKit.
    func snapshot() async throws -> NSImage {
        try await webView.takeSnapshot(configuration: nil)
    }

    // MARK: - KVO bridge

    private func observe<Value>(_ keyPath: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
        webView.observe(keyPath, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    private func sync() {
        assign(\.title, webView.title ?? "")
        assign(\.url, webView.url)
        assign(\.isLoading, webView.isLoading)
        assign(\.estimatedProgress, webView.estimatedProgress)
        assign(\.canGoBack, webView.canGoBack)
        assign(\.canGoForward, webView.canGoForward)
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TabSession, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
