import ArcXCore
import Foundation
import Testing

@Suite("URLClassifier")
struct URLClassifierTests {
    private func url(_ input: String) -> String? {
        if case .url(let url) = URLClassifier.classify(input) { return url.absoluteString }
        return nil
    }

    private func isSearch(_ input: String) -> Bool {
        if case .search = URLClassifier.classify(input) { return true }
        return false
    }

    @Test("full URLs with a scheme are kept as typed", arguments: [
        "https://apple.com",
        "http://example.com/path?q=1#frag",
        "https://www.apple.com/mac/",
        "ftp://files.example.org/pub",
        "HTTPS://Example.com",
    ])
    func fullURLs(_ input: String) {
        #expect(url(input) == input)
    }

    @Test("bare domains open over https", arguments: [
        ("apple.com", "https://apple.com"),
        ("apple.com/mac", "https://apple.com/mac"),
        ("www.apple.com/mac?x=1#top", "https://www.apple.com/mac?x=1#top"),
        ("sub.domain.co.uk", "https://sub.domain.co.uk"),
        ("example.com:8443/admin", "https://example.com:8443/admin"),
        ("my-site.dev", "https://my-site.dev"),
        ("apple.com.", "https://apple.com."),
        ("claude.ai", "https://claude.ai"),
        ("docs.rs", "https://docs.rs"),
    ])
    func bareDomains(_ input: String, _ expected: String) {
        #expect(url(input) == expected)
    }

    @Test("localhost and IP addresses open over http", arguments: [
        ("localhost", "http://localhost"),
        ("localhost:3000", "http://localhost:3000"),
        ("LOCALHOST:3000/api", "http://LOCALHOST:3000/api"),
        ("app.localhost:5173", "http://app.localhost:5173"),
        ("127.0.0.1", "http://127.0.0.1"),
        ("192.168.1.20:8080", "http://192.168.1.20:8080"),
        ("10.0.0.1/status", "http://10.0.0.1/status"),
        ("[::1]", "http://[::1]"),
        ("[::1]:8080/x", "http://[::1]:8080/x"),
        ("devbox:8080", "http://devbox:8080"),
    ])
    func localAddresses(_ input: String, _ expected: String) {
        #expect(url(input) == expected)
    }

    @Test("file, about and data URLs")
    func otherSchemes() {
        #expect(url("about:blank") == "about:blank")
        #expect(url("file:///Users/me/page.html") == "file:///Users/me/page.html")
        #expect(url("file:///tmp/a b.html") == "file:///tmp/a%20b.html")
        #expect(url("data:text/html,<h1>Hi</h1>") == "data:text/html,%3Ch1%3EHi%3C/h1%3E")
    }

    @Test("javascript: is never an address")
    func javascriptIsSearch() {
        #expect(isSearch("javascript:alert(1)"))
    }

    @Test("text with spaces is a search", arguments: [
        "what is 1.5",
        "foo.bar baz",
        "apple.com is great",
        "how to use localhost:3000",
    ])
    func spaces(_ input: String) {
        #expect(URLClassifier.classify(input) == .search(query: input))
    }

    @Test("single words, numbers and non-hosts are searches", arguments: [
        "swift",
        "1.5",
        "3.14159",
        "c/c++",
        "me@example.com",
        "foo:bar",
        "localhost:99999",
        "localhost:",
        "256.1.1.1x",
        "-bad-.com",
        "a..b",
        "?",
        "1.2.3",
    ])
    func searches(_ input: String) {
        #expect(isSearch(input))
    }

    @Test("an IPv4-looking token out of range is not an address")
    func badIPv4() {
        // Four numeric labels never make a domain (the last label must be letters), so this is a search.
        #expect(isSearch("256.1.1.1"))
    }

    @Test("surrounding whitespace is trimmed; blank input is nil")
    func whitespace() {
        #expect(url("  apple.com\n") == "https://apple.com")
        #expect(URLClassifier.classify("  swift  ") == .search(query: "swift"))
        #expect(URLClassifier.classify("") == nil)
        #expect(URLClassifier.classify(" \t\n ") == nil)
    }

    @Test("unicode hosts become punycode")
    func idn() {
        #expect(url("münchen.de") == "https://xn--mnchen-3ya.de")
        #expect(url("https://例え.jp/パス") == "https://xn--r8jz45g.jp/%E3%83%91%E3%82%B9")
        #expect(url("bücher.example/straße") == "https://xn--bcher-kva.example/stra%C3%9Fe")
    }

    @Test("a bare name.ext with a file extension is a search", arguments: [
        "readme.md", "README.MD", "index.html", "notes.txt", "Package.swift", "main.py", "archive.zip",
    ])
    func fileNames(_ input: String) {
        #expect(isSearch(input))
    }

    @Test("a scheme, slash or port makes a file-extension name an address")
    func fileNameEscapes() {
        #expect(url("readme.md/") == "https://readme.md/")
        #expect(url("https://readme.md") == "https://readme.md")
        #expect(url("readme.md:8080") == "https://readme.md:8080")
    }

    @Test("destination goes to the address, or to the engine's results page")
    func destination() {
        #expect(URLClassifier.destination(for: "apple.com")?.absoluteString == "https://apple.com")
        #expect(URLClassifier.destination(for: "swift concurrency")?.absoluteString
            == "https://duckduckgo.com/?q=swift+concurrency")
        #expect(URLClassifier.destination(for: "swift", engine: .google)?.absoluteString
            == "https://www.google.com/search?q=swift")
        #expect(URLClassifier.destination(for: "   ") == nil)
    }
}

@Suite("SearchEngine")
struct SearchEngineTests {
    @Test("queries are percent-encoded so they cannot change the URL's structure")
    func encoding() {
        let engine = SearchEngine.duckDuckGo
        #expect(engine.url(for: "a&b=c#d")?.absoluteString == "https://duckduckgo.com/?q=a%26b%3Dc%23d")
        #expect(engine.url(for: "c++ vs rust")?.absoluteString == "https://duckduckgo.com/?q=c%2B%2B+vs+rust")
        #expect(engine.url(for: "what is 1.5")?.absoluteString == "https://duckduckgo.com/?q=what+is+1.5")
        #expect(engine.url(for: "café ☕")?.absoluteString == "https://duckduckgo.com/?q=caf%C3%A9+%E2%98%95")
        #expect(engine.url(for: "50% off/now?")?.absoluteString == "https://duckduckgo.com/?q=50%25+off%2Fnow%3F")
    }

    @Test("the engine is a value and can be swapped")
    func custom() {
        let engine = SearchEngine(name: "Kagi", template: "https://kagi.com/search?q={query}")
        #expect(URLClassifier.destination(for: "hello world", engine: engine)?.absoluteString
            == "https://kagi.com/search?q=hello+world")
        #expect(SearchEngine.default == .duckDuckGo)
    }
}
