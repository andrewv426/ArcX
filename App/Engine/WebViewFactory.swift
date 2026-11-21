import Foundation
import WebKit

/// Builds the configuration every web view shares.
@MainActor
enum WebViewFactory {
    /// One configuration (and so one data store and process pool) for the whole app.
    /// Persistent for normal use; a throwaway in-memory store for test runs, so they never see
    /// or touch the user's cookies, cache or local storage.
    static let configuration: WKWebViewConfiguration = makeConfiguration(persistent: !isTestRun)

    /// Whether cookies, cache and site data outlive the process.
    static var storesDataOnDisk: Bool { configuration.websiteDataStore.isPersistent }

    static func makeConfiguration(persistent: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = persistent ? .default() : .nonPersistent()
        // WebKit's own user agent ends at "(KHTML, like Gecko)". Sites sniff for the Safari token,
        // so append what Safari appends. Safari's version has matched the macOS major version since 26.
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        configuration.applicationNameForUserAgent = "Version/\(major).0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        // WebKit's macOS default lets scripts open windows without a click. Every window request
        // becomes a tab here, so a page could open any number of tabs on load. Only a user
        // gesture (a click, a key press) may open one.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    private static var isTestRun: Bool {
        #if DEBUG
        TestHost.isActive
        #else
        false
        #endif
    }
}
