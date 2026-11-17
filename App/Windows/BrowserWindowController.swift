import AppKit
import Observation

/// The browser window: one page, edge to edge under a transparent title bar.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let session = TabSession()
    private let container = WebContainerView()

    init(startURL: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 480, height: 320)
        window.contentView = container
        window.center()
        window.setFrameAutosaveName("BrowserWindow")
        super.init(window: window)
        window.delegate = self
        container.show(session.view)
        followTitle()
        if let startURL { session.load(startURL) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        super.showWindow(sender)
        window.makeFirstResponder(session.view)
    }

    @objc func reloadPage(_ sender: Any?) {
        session.reload()
    }

    /// The window's title (used by the Window menu and Mission Control) follows the page's.
    private func followTitle() {
        let title = withObservationTracking { session.title } onChange: { [weak self] in
            Task { @MainActor in self?.followTitle() }
        }
        window?.title = title.isEmpty ? "ArcX" : title
    }
}
