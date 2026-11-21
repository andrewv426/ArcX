import AppKit
import ArcXCore

/// Keeps `BrowserState` (which tabs exist) and `TabSessionStore` (which web views exist) in step.
///
/// State flows one way at a time, so nothing loops:
/// - **State → engine**, on a `.tabs` or `.selection` change only: show the selected tab's
///   session (created and loaded on first show) and release sessions of closed tabs.
/// - **Engine → state**, through each session's `onPageChange` and `onOpenInNewTab`: record the
///   page's title and URL, or add a tab. Those produce `.content` or `.tabs` changes; a `.content`
///   change never touches the engine, and the engine never loads a URL because the state's URL
///   changed, so a page reporting its URL cannot make itself reload.
@MainActor
final class TabCoordinator {
    let state: BrowserState
    let sessions: TabSessionStore
    let startPageURL: URL?
    private let container: WebContainerView

    /// Called with the selected tab's display title (or "ArcX") after every change.
    var titleDidChange: ((String) -> Void)?

    init(state: BrowserState, sessions: TabSessionStore, container: WebContainerView, startPageURL: URL?) {
        self.state = state
        self.sessions = sessions
        self.container = container
        self.startPageURL = startPageURL
        sessions.didCreate = { [weak self] id, session in self?.wire(session, to: id) }
        state.observeChanges { [weak self] change in self?.stateDidChange(change) }
    }

    /// Shows whatever the state holds now. Called once the window exists.
    func start() { stateDidChange([.tabs, .selection]) }

    var selectedSession: TabSession? { state.selectedTabID.flatMap(sessions.existingSession(for:)) }

    // MARK: - Commands

    /// A new selected tab on the start page.
    func newTab() {
        state.addTab(url: startPageURL)
    }

    /// What the address field does with typed text: load it in the selected tab, or in a new
    /// tab when there is none. Returns the destination URL, or nil for blank text.
    @discardableResult
    func submitAddress(_ text: String) -> URL? {
        guard let url = URLClassifier.destination(for: text) else { return nil }
        if let tab = state.selectedTab {
            sessions.session(for: tab).load(url)
        } else {
            state.addTab(url: url)
        }
        return url
    }

    /// What the address field shows for a URL: its string, or nothing on the start page.
    func displayAddress(for url: URL?) -> String {
        guard let url,
              url.standardizedFileURL != startPageURL?.standardizedFileURL else { return "" }
        return url.absoluteString
    }

    /// What the address field shows for the selected tab: its URL, or nothing on the start page.
    var addressText: String { displayAddress(for: state.selectedTab?.url) }

    func goBack() { selectedSession?.goBack() }
    func goForward() { selectedSession?.goForward() }
    func reload() { selectedSession?.reload() }

    // MARK: - State → engine

    private func stateDidChange(_ change: BrowserState.Change) {
        if change.contains(.tabs) || change.contains(.selection) {
            if let tab = state.selectedTab {
                container.show(sessions.session(for: tab).view)
            } else {
                container.show(nil)
            }
            sessions.releaseSessions(keeping: Set(state.tabs.map(\.id)))
        }
        titleDidChange?(state.selectedTab?.displayTitle ?? "ArcX")
    }

    // MARK: - Engine → state

    private func wire(_ session: TabSession, to id: Tab.ID) {
        session.onPageChange = { [weak self] title, url in
            self?.state.updateTab(id, title: title, url: url)
        }
        session.onOpenInNewTab = { [weak self] url, inBackground in
            self?.state.addTab(url: url, selected: !inBackground, after: id)
        }
    }
}
