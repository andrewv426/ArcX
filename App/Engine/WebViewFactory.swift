import Foundation
import WebKit

/// Builds the configuration every web view shares.
@MainActor
enum WebViewFactory {
    /// One configuration (and so one data store and process pool) for the whole app.
    static let configuration: WKWebViewConfiguration = makeConfiguration(persistent: true)

    static func makeConfiguration(persistent: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = persistent ? .default() : .nonPersistent()
        // WebKit's own user agent ends at "(KHTML, like Gecko)". Sites sniff for the Safari token,
        // so append what Safari appends. Safari's version has matched the macOS major version since 26.
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        configuration.applicationNameForUserAgent = "Version/\(major).0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }
}
