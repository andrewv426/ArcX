import AppKit
import ArcXCore
import SwiftUI

/// The browser window: a split view with the SwiftUI sidebar (system sidebar material, under the
/// traffic lights, collapsible with ⌘S) and the selected tab's page beside it.
///
/// It builds the window and answers menu actions; `TabCoordinator` keeps tabs and web views in step.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    static let defaultSidebarWidth: CGFloat = 240
    static let sidebarWidthRange: ClosedRange<CGFloat> = 180...400
    /// The remembered sidebar width, in `AppDefaults.store` (so test runs keep their own).
    static let sidebarWidthKey = "SidebarWidth"

    let state: BrowserState
    let sessions = TabSessionStore()
    let tabs: TabCoordinator
    let addressField = AddressFieldFocus()
    let container = WebContainerView()
    let splitViewController = NSSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    /// Height of the title bar area; the page is pushed down by this much when the sidebar is collapsed.
    private(set) var titlebarHeight: CGFloat = 0
    private var widthRestored = false
    private var collapseObservation: NSKeyValueObservation?

    init(state: BrowserState, startPageURL: URL?) {
        self.state = state
        tabs = TabCoordinator(state: state, sessions: sessions, container: container, startPageURL: startPageURL)
        let size = NSSize(width: 1280, height: 820)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 600, height: 360)
        super.init(window: window)
        window.delegate = self

        titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let metrics = Self.titlebarMetrics(of: window, titlebarHeight: titlebarHeight)
        let sidebarHost = NSHostingController(rootView: SidebarView(
            state: state, sessions: sessions, tabs: tabs, addressFocus: addressField, titlebar: metrics,
            newTab: { [weak self] in self?.newTab(nil) },
            submitAddress: { [weak self] in self?.submitAddress($0) }
        ))
        // The split view, not SwiftUI's ideal size, decides the sidebar's width.
        sidebarHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = Self.sidebarWidthRange.lowerBound
        sidebarItem.maximumThickness = Self.sidebarWidthRange.upperBound
        sidebarItem.canCollapse = true
        self.sidebarItem = sidebarItem
        let content = NSViewController()
        content.view = container
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: content))
        splitViewController.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = splitViewController
        window.setContentSize(size)
        window.center()

        #if DEBUG
        let isTestRun = TestHost.isActive
        #else
        let isTestRun = false
        #endif
        // A test run must never save its (off-screen) frame over the user's.
        if !isTestRun { window.setFrameAutosaveName("BrowserWindow") }

        restoreSidebarWidth()
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                               object: splitViewController.splitView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebarLayoutDidChange() }
        }
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sidebarLayoutDidChange() }
        }

        container.onNewTab = { [weak self] in self?.newTab(nil) }
        tabs.titleDidChange = { [weak window] title in window?.title = title }
        tabs.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        // Otherwise AppKit starts the window on its first key view, the address field.
        window.initialFirstResponder = container.content
        window.layoutIfNeeded()
        #if DEBUG
        if TestHost.isBackground {
            // Shown so AppKit and WebKit lay out and draw, but never brought forward or made key.
            TestHost.prepare(window)
            window.orderBack(nil)
            focusPage()
            return
        }
        #endif
        super.showWindow(sender)
        focusPage()
    }

    // MARK: - Menu actions

    @objc func newTab(_ sender: Any?) {
        tabs.newTab()
        openLocation(sender)
    }

    /// ⌘L: the address field, with its text selected. Shows the sidebar first if it is collapsed.
    @objc func openLocation(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        addressField.focus(text: tabs.addressText, tabID: state.selectedTabID)
    }

    /// Return in the address field: load what was typed (see `TabCoordinator.submitAddress`) and
    /// hand the keyboard to the page.
    @discardableResult
    func submitAddress(_ text: String) -> Bool {
        guard tabs.submitAddress(text) else { return false }
        focusPage(leavingAddressField: true)
        return true
    }

    /// ⌘W closes the selected tab, or the window when there are no tabs.
    @objc func closeTab(_ sender: Any?) {
        if let id = state.selectedTabID {
            state.closeTab(id)
            focusPage()
        } else {
            window?.performClose(sender)
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        state.reopenLastClosedTab()
        focusPage()
    }

    @objc func reloadPage(_ sender: Any?) { tabs.reload() }
    @objc func navigateBack(_ sender: Any?) { tabs.goBack() }
    @objc func navigateForward(_ sender: Any?) { tabs.goForward() }

    @objc func selectNextTab(_ sender: Any?) {
        state.selectNextTab()
        focusPage()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        state.selectPreviousTab()
        focusPage()
    }

    /// ⌘1…⌘9; the menu item's tag is the number.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag else { return }
        if state.selectTab(atShortcutNumber: number) { focusPage() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(navigateBack(_:)): tabs.selectedSession?.canGoBack == true
        case #selector(navigateForward(_:)): tabs.selectedSession?.canGoForward == true
        case #selector(reloadPage(_:)): tabs.selectedSession != nil
        case #selector(reopenClosedTab(_:)): !state.recentlyClosed.isEmpty
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): state.tabs.count > 1
        case #selector(selectTabByNumber(_:)):
            item.tag == 9 ? !state.tabs.isEmpty : state.tabs.indices.contains(item.tag - 1)
        default: true
        }
    }

    // MARK: - Layout

    /// The selected page takes the keyboard, unless the user is typing in the address field.
    private func focusPage(leavingAddressField: Bool = false) {
        guard let window, let page = container.content, leavingAddressField || !addressField.isEditing else { return }
        window.makeFirstResponder(page)
    }

    private func restoreSidebarWidth() {
        let stored = AppDefaults.store.double(forKey: Self.sidebarWidthKey)
        let width = stored > 0 ? CGFloat(stored) : Self.defaultSidebarWidth
        let range = Self.sidebarWidthRange
        window?.layoutIfNeeded()
        splitViewController.splitView.setPosition(min(max(width, range.lowerBound), range.upperBound), ofDividerAt: 0)
        widthRestored = true
        sidebarLayoutDidChange()
    }

    /// Keeps the page clear of the traffic lights when the sidebar is collapsed (they sit over the
    /// sidebar otherwise), and remembers the sidebar's width.
    private func sidebarLayoutDidChange() {
        guard let sidebarItem else { return }
        let inset = sidebarItem.isCollapsed ? titlebarHeight : 0
        if container.topInset != inset { container.topInset = inset }
        guard widthRestored, !sidebarItem.isCollapsed else { return }
        let width = sidebarWidth
        let stored = CGFloat(AppDefaults.store.double(forKey: Self.sidebarWidthKey))
        if Self.sidebarWidthRange.contains(width), abs(width - stored) >= 1 {
            AppDefaults.store.set(Double(width.rounded()), forKey: Self.sidebarWidthKey)
        }
    }

    /// The sidebar's width as the split view defines it: the divider's position, which
    /// `minimumThickness`/`maximumThickness` and `setPosition` use. Not the hosted view's width:
    /// a floating (Liquid Glass) sidebar insets its view by a few points from the divider, and
    /// remembering that smaller number would shrink the sidebar on every launch.
    var sidebarWidth: CGFloat {
        let splitView = splitViewController.splitView
        var view: NSView? = sidebarItem.viewController.view
        while let current = view, current.superview !== splitView { view = current.superview }
        return (view ?? sidebarItem.viewController.view).frame.width
    }

    /// Where the traffic lights end and how tall a row centred on them is, in window coordinates.
    private static func titlebarMetrics(of window: NSWindow, titlebarHeight: CGFloat) -> TitlebarMetrics {
        window.layoutIfNeeded()
        let fallback = TitlebarMetrics(trafficLightsTrailing: 78, rowHeight: max(titlebarHeight, 28))
        guard let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton) else { return fallback }
        let closeFrame = close.convert(close.bounds, to: nil)
        let zoomFrame = zoom.convert(zoom.bounds, to: nil)
        guard closeFrame.height > 0, zoomFrame.maxX > 0 else { return fallback }
        let centreFromTop = window.frame.height - closeFrame.midY
        return TitlebarMetrics(trafficLightsTrailing: zoomFrame.maxX + 6, rowHeight: max(28, 2 * centreFromTop))
    }
}
