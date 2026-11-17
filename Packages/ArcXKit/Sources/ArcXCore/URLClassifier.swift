import Foundation

/// What a string typed into the address bar means.
public enum AddressInput: Hashable, Sendable {
    /// Go to this address.
    case url(URL)
    /// Search for this text.
    case search(query: String)
}

/// Decides whether typed text is an address or a search. Foundation only, and no network:
/// the decision is made from the text alone, the same way every time.
///
/// The rules, in order (surrounding whitespace is trimmed first; blank input is `nil`):
///
/// 1. **An explicit scheme is a URL.** `scheme://…` for any well-formed scheme, plus the
///    scheme-only forms `about:` and `data:`. Characters a URL cannot hold (spaces, non-ASCII)
///    are percent-encoded and IDN hosts are converted to punycode, so `file:///tmp/a b.html`
///    still loads. `javascript:` is never treated as an address.
/// 2. **Whitespace inside means search.** `what is 1.5`, `foo.bar baz`.
/// 3. **Otherwise the text must start with a host**, optionally followed by `:port` and then a
///    path, query or fragment. An `@` before the path (`me@example.com`) means search. The host is:
///    - `localhost` or `*.localhost`, or an IPv4 address (`127.0.0.1`), or a bracketed IPv6
///      address (`[::1]`). These open over `http`, because local servers rarely have TLS.
///    - a domain: two or more dot-separated labels of letters, digits and hyphens (Unicode letters
///      allowed, so `münchen.de` works), whose last label is letters only and at least two long.
///      These open over `https`. A bare number like `1.5` or `3.14` is a search.
///    - a single word with an explicit port (`devbox:8080`) opens over `http`. A single word
///      on its own (`swift`) or with a path (`c/c++`) is a search.
///
/// **Ambiguous single tokens with a dot.** Without a list of every top-level domain, `readme.md`
/// looks like a domain (`.md` is Moldova). The rule: a bare `name.ext` with no port, path or scheme
/// is a search when `ext` is a common file extension (``fileExtensions``), and an address otherwise.
/// Typing a scheme, a trailing slash or a path (`readme.md/`, `https://readme.md`) always makes it
/// an address. The list deliberately leaves out extensions that are popular web domains
/// (`.ai`, `.app`, `.io`, `.rs`, `.sh`, `.so`). The alternative, a bundled IANA list, was rejected:
/// it goes stale and still cannot tell `readme.md` from a real Moldovan site.
public enum URLClassifier {
    public static func classify(_ input: String) -> AddressInput? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if hasExplicitScheme(text) {
            if let url = URL(string: text, encodingInvalidCharacters: true), url.scheme != nil {
                return .url(url)
            }
            return .search(query: text)
        }
        if text.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
            return .search(query: text)
        }
        if let scheme = impliedScheme(text),
           let url = URL(string: "\(scheme)://\(text)", encodingInvalidCharacters: true),
           url.host() != nil {
            return .url(url)
        }
        return .search(query: text)
    }

    /// Where typed text leads: the address itself, or `engine`'s results page for it.
    public static func destination(for input: String, engine: SearchEngine = .default) -> URL? {
        switch classify(input) {
        case .url(let url): url
        case .search(let query): engine.url(for: query)
        case nil: nil
        }
    }

    /// Bare `name.ext` tokens with these endings are searches, not domains. Lowercase.
    public static let fileExtensions: Set<String> = [
        "md", "markdown", "txt", "rtf", "html", "htm", "json", "yaml", "yml", "xml", "csv", "log",
        "pdf", "doc", "docx", "png", "jpg", "jpeg", "gif", "heic", "svg", "mov", "mp3", "mp4",
        "zip", "dmg", "pkg", "exe", "swift", "js", "ts", "py", "rb", "cpp", "java", "kt",
    ]

    // MARK: - Rules

    private static let opaqueSchemes = ["about:", "data:"]

    private static func hasExplicitScheme(_ text: String) -> Bool {
        let lower = text.lowercased()
        if opaqueSchemes.contains(where: lower.hasPrefix) { return true }
        guard let range = text.range(of: "://") else { return false }
        let scheme = text[..<range.lowerBound]
        guard let first = scheme.unicodeScalars.first, CharacterSet.asciiLetters.contains(first) else { return false }
        return scheme.unicodeScalars.allSatisfy { CharacterSet.schemeCharacters.contains($0) }
    }

    /// The scheme to put in front of `text` if it starts with a host, or nil if it is a search.
    private static func impliedScheme(_ text: String) -> String? {
        let hostEnd = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        let hostPort = text[..<hostEnd]
        let hasRest = hostEnd != text.endIndex
        guard !hostPort.isEmpty, !hostPort.contains("@") else { return nil }

        // Bracketed IPv6, with an optional port.
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            let address = hostPort[hostPort.index(after: hostPort.startIndex)..<close]
            let after = hostPort[hostPort.index(after: close)...]
            guard address.contains(":"),
                  address.unicodeScalars.allSatisfy({ CharacterSet.ipv6Characters.contains($0) }),
                  after.isEmpty || (after.hasPrefix(":") && isPort(after.dropFirst()))
            else { return nil }
            return "http"
        }

        let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        if parts.count == 2, !isPort(parts[1]) { return nil }
        let hasPort = parts.count == 2
        var host = parts[0].lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }

        if host == "localhost" || host.hasSuffix(".localhost") || isIPv4(host) { return "http" }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 1 {
            return hasPort && isLabel(labels[0]) ? "http" : nil
        }
        guard labels.allSatisfy(isLabel), let tld = labels.last,
              tld.count >= 2, tld.allSatisfy(\.isLetter)
        else { return nil }
        if !hasPort, !hasRest, fileExtensions.contains(String(tld)) { return nil }
        return "https"
    }

    private static func isPort(_ text: Substring) -> Bool {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy(\.isASCIIDigit), let port = Int(text) else { return false }
        return (1...65_535).contains(port)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3 && octet.allSatisfy(\.isASCIIDigit) && Int(octet).map { $0 <= 255 } == true
        }
    }

    /// One DNS label: letters (any script), digits and inner hyphens, at most 63 characters.
    private static func isLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

private extension CharacterSet {
    static let asciiLetters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let schemeCharacters = asciiLetters.union(CharacterSet(charactersIn: "0123456789+-."))
    static let ipv6Characters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
}
