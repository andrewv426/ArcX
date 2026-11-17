import Foundation

/// Where a search typed into the address bar goes. A plain value, so the default can be swapped
/// (and later stored as a preference) without touching the classifier.
public struct SearchEngine: Hashable, Sendable {
    public var name: String
    /// A search URL with `{query}` where the percent-encoded query goes.
    public var template: String

    public init(name: String, template: String) {
        self.name = name
        self.template = template
    }

    public static let duckDuckGo = SearchEngine(name: "DuckDuckGo", template: "https://duckduckgo.com/?q={query}")
    public static let google = SearchEngine(name: "Google", template: "https://www.google.com/search?q={query}")

    /// The engine used when the user has not chosen one.
    public static let `default` = duckDuckGo

    /// The results page for `query`, or nil if the template does not make a valid URL.
    ///
    /// Everything outside RFC 3986's unreserved characters is percent-encoded, and spaces become `+`,
    /// so `&`, `#`, `+` and `=` in the query can never be read as part of the URL's own syntax.
    public func url(for query: String) -> URL? {
        let encoded = query
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? "" }
            .joined(separator: "+")
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
