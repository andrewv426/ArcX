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

    /// Called with the page's title and URL whenever either changes, once the page has a URL.
    /// Synchronous and direct, so the tab's record in `BrowserState` never lags behind. The title
    /// is nil while a page is loading and has not named itself yet, so a tab keeps its previous
    /// (or restored) title instead of flashing blank; a page that finishes without a title reports "".
    @ObservationIgnored var onPageChange: ((_ title: String?, _ url: URL) -> Void)?
    /// Called when the page asks for a link to open in another tab: `target=_blank` and
    /// `window.open` (selected), or ⌘-click (in the background; ⇧⌘-click selects it).
    /// Proper pop-up handling (blocking, sized windows, opener access) is M5.
    @ObservationIgnored var onOpenInNewTab: ((_ url: URL, _ inBackground: Bool) -> Void)?

    @ObservationIgnored private let webView: WKWebView
    @ObservationIgnored private let delegate = PageDelegate()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastReport: (title: String?, url: URL)?

    /// The web view, as a plain view for the window to host.
    var view: NSView { webView }

    init(configuration: WKWebViewConfiguration = WebViewFactory.configuration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        // WebKit posts KVO on the main thread. Every change re-reads all six values; each is only
        // written when it differs, so observers fire for real changes only.
        observations = [
            observe(\.title), observe(\.url), observe(\.isLoading),
            observe(\.estimatedProgress), observe(\.canGoBack), observe(\.canGoForward),
        ]
        delegate.session = self
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

    #if DEBUG
    /// Sends a left click with `modifiers` straight to the web view at a point in page (CSS)
    /// coordinates, through AppKit's mouse event path rather than the window server. For the
    /// self-test, whose windows ignore real mouse events.
    func sendClick(atPagePoint point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let window = webView.window else { return }
        let local = webView.isFlipped ? point : CGPoint(x: point.x, y: webView.bounds.height - point.y)
        let location = webView.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
    }
    #endif

    fileprivate func openInNewTab(_ url: URL, inBackground: Bool) {
        onOpenInNewTab?(url, inBackground)
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
        guard let url else { return }
        let report = (title: isLoading && title.isEmpty ? nil : title, url: url)
        if let lastReport, lastReport.title == report.title, lastReport.url == report.url { return }
        lastReport = report
        onPageChange?(report.title, report.url)
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TabSession, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// WebKit's delegates need an `NSObject`; this one turns new-window requests into
/// "open in a new tab" reports and lets everything else through.
@MainActor
private final class PageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var session: TabSession?

    /// ⌘-click on a link: cancel it here and open it in a new background tab (⇧⌘: selected).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let flags = navigationAction.modifierFlags
        if navigationAction.navigationType == .linkActivated, flags.contains(.command),
           let url = navigationAction.request.url {
            session?.openInNewTab(url, inBackground: !flags.contains(.shift))
            return .cancel
        }
        return .allow
    }

    /// `target=_blank` and `window.open`: no new web view (WebKit then cancels the pop-up); the
    /// URL opens in a new tab instead. A request with no real URL (`window.open()` used to write
    /// into a blank window) is dropped until M5.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, !url.absoluteString.isEmpty, url.absoluteString != "about:blank" {
            let flags = navigationAction.modifierFlags
            session?.openInNewTab(url, inBackground: flags.contains(.command) && !flags.contains(.shift))
        }
        return nil
    }
}
