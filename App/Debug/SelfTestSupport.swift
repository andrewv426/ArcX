#if DEBUG
import AppKit
import ArcXCore

/// Local pages the self-test loads. Each has a large block of one known colour, so a snapshot can
/// tell a painted page from a blank one.
enum Fixtures {
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
    /// Links that ask for new tabs: `target=_blank`, and a plain link for the ⌘-click check.
    static let links = """
        <!doctype html><html><head><meta charset="utf-8"><title>Links</title>
        <style>html,body{margin:0;height:100%;background:#fff;font:16px system-ui}
        #band{height:30vh;background:#2f9e44}</style></head>
        <body><div id="band"></div><h1>Links</h1>
        <p><a id="blank" href="fixture%20c.html" target="_blank">Fixture C in a new tab</a></p>
        <p><a id="plain" href="b.html">Fixture B</a></p></body></html>
        """

    /// The fixture files, written into `<output>/fixtures/` by the main phase and reused by later ones.
    struct Files {
        let directory: URL
        var pageA: URL { directory.appendingPathComponent("a.html") }
        var pageB: URL { directory.appendingPathComponent("b.html") }
        var pageC: URL { directory.appendingPathComponent("fixture c.html") }
        var links: URL { directory.appendingPathComponent("links.html") }

        init(output: URL) { directory = output.appendingPathComponent("fixtures", isDirectory: true) }

        func write() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Fixtures.pageA.write(to: pageA, atomically: true, encoding: .utf8)
            try Fixtures.pageB.write(to: pageB, atomically: true, encoding: .utf8)
            try Fixtures.pageC.write(to: pageC, atomically: true, encoding: .utf8)
            try Fixtures.links.write(to: links, atomically: true, encoding: .utf8)
        }
    }
}

/// True when two URLs name the same page, ignoring how a file path was spelled.
func samePage(_ lhs: URL?, _ rhs: URL?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return lhs.standardizedFileURL.absoluteString == rhs.standardizedFileURL.absoluteString
}

/// A snapshot redrawn into a plain 8-bit sRGB bitmap, so colours can be compared with the CSS values
/// the fixtures use whatever colour space WebKit rendered in. Rows run top to bottom.
struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]
    private let image: CGImage

    init?(_ snapshot: NSImage) {
        guard let source = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        self.init(source)
    }

    init?(_ source: CGImage) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
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

    /// Pixel rows and columns of `region` (in pixels, origin top left), clipped to the image.
    private func span(_ region: CGRect?) -> (xs: Range<Int>, ys: Range<Int>) {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let clipped = (region ?? full).intersection(full).integral
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return (0..<0, 0..<0) }
        return (Int(clipped.minX)..<Int(clipped.maxX), Int(clipped.minY)..<Int(clipped.maxY))
    }

    private func forEachPixel(in region: CGRect?, _ body: (UInt8, UInt8, UInt8, UInt8) -> Void) {
        let (xs, ys) = span(region)
        for y in ys {
            for x in xs {
                let index = (y * width + x) * 4
                body(bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
            }
        }
    }

    private func area(_ region: CGRect?) -> Int {
        let (xs, ys) = span(region)
        return xs.count * ys.count
    }

    /// The share of pixels within a small tolerance of `colour`.
    func share(of colour: (UInt8, UInt8, UInt8), tolerance: Int = 10, in region: CGRect? = nil) -> Double {
        var count = 0
        forEachPixel(in: region) { r, g, b, _ in
            if abs(Int(r) - Int(colour.0)) <= tolerance, abs(Int(g) - Int(colour.1)) <= tolerance,
               abs(Int(b) - Int(colour.2)) <= tolerance { count += 1 }
        }
        return Double(count) / Double(max(1, area(region)))
    }

    /// How many pixels clearly differ from the region's background (its most common colour): at
    /// least `threshold` apart in some channel. A blank region has none; text, icons and blocks of
    /// colour all count, while anti-aliasing noise and gradients in the background mostly do not.
    /// An absolute count, so it does not drift with the window size the way a share does.
    func inkCount(in region: CGRect? = nil, threshold: Int = 48) -> Int {
        var counts: [UInt32: Int] = [:]
        forEachPixel(in: region) { r, g, b, a in
            counts[UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a), default: 0] += 1
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        let br = Int(background >> 24 & 0xFF), bg = Int(background >> 16 & 0xFF), bb = Int(background >> 8 & 0xFF)
        var ink = 0
        forEachPixel(in: region) { r, g, b, _ in
            if abs(Int(r) - br) >= threshold || abs(Int(g) - bg) >= threshold || abs(Int(b) - bb) >= threshold { ink += 1 }
        }
        return ink
    }
}

/// A picture of the whole window: AppKit and SwiftUI drawn by `cacheDisplay` (which leaves web
/// content blank, because WebKit draws in another process), with WebKit's own snapshot of the
/// visible page painted into the page's rectangle on top.
struct WindowPicture {
    let pixels: Pixels
    /// The sidebar and the content pane, in pixels with the origin at the top left.
    let sidebar: CGRect
    let content: CGRect

    @MainActor
    static func capture(_ controller: BrowserWindowController) async throws -> WindowPicture {
        guard let window = controller.window, let frameView = window.contentView?.superview ?? window.contentView else {
            throw CocoaError(.featureUnsupported)
        }
        frameView.layoutSubtreeIfNeeded()
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { throw CocoaError(.featureUnsupported) }
        frameView.cacheDisplay(in: bounds, to: rep)

        var page: (image: NSImage, rect: NSRect)?
        if let pageView = controller.container.content, let session = controller.tabs.selectedSession {
            page = (try await session.snapshot(), pageView.convert(pageView.bounds, to: frameView))
        }
        func drawingRect(_ rect: NSRect) -> NSRect {
            frameView.isFlipped ? NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
        }

        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.featureUnsupported) }
        // The size (in points) must be set before the context is made, or drawing is not scaled.
        output.size = bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: output) else { throw CocoaError(.featureUnsupported) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        if let page { page.image.draw(in: drawingRect(page.rect)) }
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = output.cgImage, let pixels = Pixels(cgImage) else { throw CocoaError(.featureUnsupported) }
        let scale = CGFloat(pixels.width) / bounds.width
        func pixelRect(of view: NSView) -> CGRect {
            let rect = drawingRect(view.convert(view.bounds, to: frameView))
            // Drawing rects have the origin at the bottom left; pixel rows start at the top.
            return CGRect(x: rect.minX * scale, y: (bounds.height - rect.maxY) * scale,
                          width: rect.width * scale, height: rect.height * scale)
        }
        return WindowPicture(pixels: pixels, sidebar: pixelRect(of: controller.sidebarItem.viewController.view),
                             content: pixelRect(of: controller.container))
    }
}
#endif
