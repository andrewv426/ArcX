import Foundation

/// One tab as data: where it points and what it is called. A tab exists, is ordered, selected
/// and saved without any web view; the engine attaches one only when the tab is shown.
public struct Tab: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var url: URL?
    /// The page's own title, as last reported by the engine. Empty until a page reports one.
    public var title: String

    public init(id: UUID = UUID(), url: URL?, title: String = "") {
        self.id = id
        self.url = url
        self.title = title
    }

    /// What the sidebar and window show: the page title, else the URL's host, else "New Tab".
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = url?.host(percentEncoded: false), !host.isEmpty { return host }
        return "New Tab"
    }
}
