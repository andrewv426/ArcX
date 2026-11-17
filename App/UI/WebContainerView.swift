import AppKit

/// Hosts whichever page view is current, pinned edge to edge. It only ever sees a plain `NSView`
/// handed over by the engine, so swapping tabs later is swapping one subview.
final class WebContainerView: NSView {
    private(set) var content: NSView?

    func show(_ view: NSView?) {
        guard view !== content else { return }
        content?.removeFromSuperview()
        content = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
