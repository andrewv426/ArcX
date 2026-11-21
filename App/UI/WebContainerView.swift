import AppKit
import SwiftUI

/// Hosts the selected tab's page, pinned edge to edge, or the empty state when there are no tabs.
/// It only ever sees a plain `NSView` handed over by the engine, so switching tabs is swapping one
/// subview; a page that is not shown is out of the view hierarchy and WebKit throttles it.
final class WebContainerView: NSView {
    /// The page view on show, or nil while the empty state is up.
    private(set) var content: NSView?
    private let emptyState: NSView
    private var shown: NSView?
    private var topConstraint: NSLayoutConstraint?

    /// Space kept clear at the top, for the traffic lights when the sidebar is collapsed.
    var topInset: CGFloat = 0 {
        didSet { topConstraint?.constant = topInset }
    }

    var isShowingEmptyState: Bool { shown === emptyState }

    /// What the empty state's New Tab button does.
    var onNewTab: (@MainActor () -> Void)? {
        get { relay.action }
        set { relay.action = newValue }
    }
    private let relay: Relay

    init() {
        let relay = Relay()
        self.relay = relay
        emptyState = NSHostingView(rootView: EmptyStateView { relay.action?() })
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ view: NSView?) {
        let target = view ?? emptyState
        guard target !== shown else { return }
        shown?.removeFromSuperview()
        shown = target
        content = view
        target.translatesAutoresizingMaskIntoConstraints = false
        addSubview(target)
        let top = target.topAnchor.constraint(equalTo: topAnchor, constant: topInset)
        topConstraint = top
        NSLayoutConstraint.activate([
            target.leadingAnchor.constraint(equalTo: leadingAnchor),
            target.trailingAnchor.constraint(equalTo: trailingAnchor),
            top,
            target.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

@MainActor
private final class Relay {
    var action: (@MainActor () -> Void)?
}

/// What the content pane shows with no tabs open.
private struct EmptyStateView: View {
    let newTab: @MainActor () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Tabs Open", systemImage: "square.on.square.dashed")
        } description: {
            Text("Open a new tab with ⌘T.")
        } actions: {
            Button("New Tab", action: newTab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
