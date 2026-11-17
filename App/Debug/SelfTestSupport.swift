#if DEBUG
import AppKit
import ArcXCore

/// An in-process smoke test, run with `ARCX_SELFTEST=<output dir>` (see `Scripts/selftest.sh`).
///
/// It drives the real window and `TabSession` against local fixture pages written into the output
/// directory (never the network), renders the page to PNG files, and writes `result.txt`: one line
/// per check and a final `RESULT pass=N fail=N skip=N`. The process exits non-zero on any failure.
@MainActor
enum SelfTest {
    static func run(controller: BrowserWindowController, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let session = controller.session
        var log: [String] = []
        var passed = 0, failed = 0, skipped = 0

        func check(_ condition: Bool, _ what: String) {
            log.append((condition ? "ok   " : "FAIL ") + what)
            if condition { passed += 1 } else { failed += 1 }
        }
        /// Some behaviour only happens when the app has keyboard focus. A run in the background never
        /// takes focus, so such checks are skipped and listed, never passed silently.
        /// Wrap them as `if needsFocus("what is checked") { ... }`.
        func needsFocus(_ what: String) -> Bool {
            if NSApp.isActive { return true }
            log.append("skip \(what): needs keyboard focus; run ARCX_FOREGROUND=1 Scripts/selftest.sh")
            skipped += 1
            return false
        }
        /// Waits for a condition instead of guessing a delay, so the test is not timing-sensitive.
        func waitFor(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            return condition()
        }
        func settled(at url: URL? = nil, title: String) async -> Bool {
            await waitFor {
                !session.isLoading && session.title == title && (url == nil || session.url?.standardizedFileURL == url?.standardizedFileURL)
            }
        }
        func javaScript(_ body: String) async -> String? {
            do { return try await session.callJavaScript(body) as? String } catch {
                log.append("note JavaScript failed: \(error.localizedDescription)")
                return nil
            }
        }
        /// Renders the page through WebKit, writes `<name>.png` and returns its pixels for checks.
        func snapshot(_ name: String) async -> Pixels? {
            do {
                let image = try await session.snapshot()
                guard let pixels = Pixels(image) else { check(false, "\(name): the snapshot has no bitmap"); return nil }
                try pixels.png().write(to: output.appendingPathComponent("\(name).png"))
                return pixels
            } catch {
                check(false, "\(name): snapshot failed: \(error.localizedDescription)")
                return nil
            }
        }

        // MARK: Fixtures

        let fixtures = output.appendingPathComponent("fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let pageA = fixtures.appendingPathComponent("a.html")
        let pageB = fixtures.appendingPathComponent("b.html")
        let pageC = fixtures.appendingPathComponent("fixture c.html")
        do {
            try Fixtures.pageA.write(to: pageA, atomically: true, encoding: .utf8)
            try Fixtures.pageB.write(to: pageB, atomically: true, encoding: .utf8)
            try Fixtures.pageC.write(to: pageC, atomically: true, encoding: .utf8)
        } catch {
            check(false, "write the fixture pages: \(error.localizedDescription)")
        }

        // MARK: Start page

        let startPage = Bundle.main.url(forResource: "start", withExtension: "html")
        check(startPage != nil, "the start page is bundled")
        let started = await settled(at: startPage, title: "ArcX")
        check(started, "the start page loads and TabSession.title/url follow it, got '\(session.title)' at \(session.url?.absoluteString ?? "nil")")
        check(!session.isLoading && session.estimatedProgress == 1, "loading ends: isLoading false, progress \(session.estimatedProgress)")
        check(!session.canGoBack && !session.canGoForward, "nothing to go back or forward to on launch")
        if let pixels = await snapshot("01-start-page") {
            let share = pixels.dominantShare()
            // The page is mostly background; its mark and text are about 1% of the pixels. Blank is 100%.
            check(pixels.width > 100 && pixels.height > 100 && share < 0.997,
                  "the start page snapshot is not blank (\(pixels.width)×\(pixels.height) px, most common colour "
                  + String(format: "%.1f%%)", share * 100))
        }

        let agent = await javaScript("return navigator.userAgent") ?? ""
        check(agent.contains("Safari/") && agent.contains("Version/"), "the user agent looks like Safari: \(agent)")
        check(!WebViewFactory.storesDataOnDisk, "web data is not persistent in a test run")
        check(AppDefaults.store !== UserDefaults.standard, "a test run uses its own preferences (\(TestHost.defaultsSuite))")

        // MARK: Navigation

        session.load(pageA)
        check(await settled(at: pageA, title: "Fixture A"), "a local page loads, got '\(session.title)'")
        check(await waitFor { controller.window?.title == "Fixture A" }, "the window title follows the page")
        check(await javaScript("return document.getElementById('js').textContent + '|' + (6 * 7)") == "JavaScript ran|42",
              "JavaScript runs in the page")
        check(session.canGoBack && !session.canGoForward, "after one navigation: can go back, not forward")
        if let pixels = await snapshot("02-fixture-a") {
            let banner = pixels.share(of: (0x1E, 0x6F, 0xFF))
            check(banner > 0.25 && banner < 0.6, "the page is painted: its blue banner covers \(Int(banner * 100))% of the snapshot (expected 25–60%)")
        }

        session.load(pageB)
        check(await settled(at: pageB, title: "Fixture B"), "a second page loads")
        check(session.canGoBack && !session.canGoForward, "on the second page: can go back, not forward")

        session.goBack()
        check(await settled(at: pageA, title: "Fixture A"), "goBack() returns to the first page")
        check(await waitFor { session.canGoBack && session.canGoForward }, "after going back: can go back (to the start page) and forward")

        session.goForward()
        check(await settled(at: pageB, title: "Fixture B"), "goForward() returns to the second page")
        check(await waitFor { session.canGoBack && !session.canGoForward }, "after going forward: nothing further forward")
        if let pixels = await snapshot("03-fixture-b") {
            let block = pixels.share(of: (0xE6, 0x49, 0x80))
            check(block > 0.25, "the second page is painted: its pink block covers \(Int(block * 100))% of the snapshot")
        }

        // MARK: Address bar path: typed text -> URLClassifier -> TabSession.load

        let typedFile = "  file://\(pageC.path)  "
        if case .url(let url) = URLClassifier.classify(typedFile) {
            session.load(url)
            check(await settled(at: pageC, title: "Fixture C"), "a typed file:// path with a space loads through URLClassifier, got \(url.absoluteString)")
        } else {
            check(false, "URLClassifier reads a typed file:// path as an address")
        }
        let typedData = "data:text/html,<title>Data fixture</title><p>from a data URL</p>"
        if case .url(let url) = URLClassifier.classify(typedData) {
            session.load(url)
            check(await settled(title: "Data fixture"), "a typed data: URL loads through URLClassifier, got '\(session.title)'")
        } else {
            check(false, "URLClassifier reads a typed data: URL as an address")
        }
        check(!session.isLoading && session.estimatedProgress == 1, "loading has ended after the last navigation")

        // MARK: Focus and window state

        if needsFocus("the browser window is key with the page as first responder"),
           let window = controller.window {
            let responder = window.firstResponder as? NSView
            check(window.isKeyWindow && responder?.isDescendant(of: session.view) == true,
                  "the browser window is key with the page as first responder")
        }
        if let problem = TestHost.savedWindowProblem() {
            check(false, problem)
        } else {
            check(true, "a test run does not restore or save the window")
        }
        if TestHost.focusTakenCount > 0 {
            log.append("note macOS made the background app active \(TestHost.focusTakenCount) time(s); it gave focus straight back")
        }

        log.append("RESULT pass=\(passed) fail=\(failed) skip=\(skipped)")
        try? (log.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        exit(failed == 0 ? 0 : 1)
    }
}

/// Local pages the self-test loads. Each has a large block of one known colour, so a snapshot can
/// tell a painted page from a blank one.
private enum Fixtures {
    static let pageA = """
        <!doctype html><html><head><meta charset="utf-8"><title>Fixture A</title>
        <style>html,body{margin:0;height:100%;background:#fff;font:16px system-ui}
        #banner{height:40vh;background:#1e6fff}</style></head>
        <body><div id="banner"></div><h1>Fixture A</h1><p id="js">JavaScript did not run</p>
        <a href="b.html">to B</a>
        <script>document.getElementById('js').textContent = 'JavaScript ran'</script></body></html>
        """
    static let pageB = """
        <!doctype html><html><head><meta charset="utf-8"><title>Fixture B</title>
        <style>html,body{margin:0;height:100%;background:#fff;font:16px system-ui}
        #block{height:50vh;background:#e64980}</style></head>
        <body><div id="block"></div><h1>Fixture B</h1><a href="a.html">to A</a></body></html>
        """
    static let pageC = """
        <!doctype html><html><head><meta charset="utf-8"><title>Fixture C</title></head>
        <body><h1>Fixture C</h1><p>Loaded from a typed file:// path.</p></body></html>
        """
}

/// A snapshot redrawn into a plain 8-bit sRGB bitmap, so colours can be compared with the CSS values
/// the fixtures use whatever colour space WebKit rendered in.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]
    private let image: CGImage

    init?(_ snapshot: NSImage) {
        guard let source = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = source.width, height = source.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        guard let drawn, width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        bytes = buffer
        image = drawn
    }

    func png() throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// The share of pixels within a small tolerance of `colour`.
    func share(of colour: (UInt8, UInt8, UInt8), tolerance: Int = 10) -> Double {
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if abs(Int(bytes[index]) - Int(colour.0)) <= tolerance,
               abs(Int(bytes[index + 1]) - Int(colour.1)) <= tolerance,
               abs(Int(bytes[index + 2]) - Int(colour.2)) <= tolerance {
                count += 1
            }
        }
        return Double(count) / Double(width * height)
    }

    /// The share of the single most common colour. A blank (unpainted) snapshot is all one colour.
    func dominantShare() -> Double {
        var counts: [UInt32: Int] = [:]
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let key = UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
            counts[key, default: 0] += 1
        }
        return Double(counts.values.max() ?? 0) / Double(width * height)
    }
}
#endif
