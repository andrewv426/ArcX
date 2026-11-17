import ArcXCore
import Foundation
import Observation

/// The live web views, keyed by tab. A tab gets its `TabSession` the first time it is shown, and
/// its URL is loaded then, so tabs restored at launch cost nothing until the user opens them.
/// Closing a tab releases its session (and with it the web view and its WebContent process).
///
/// Observable, so views that read `existingSession(for:)` update when a session appears or goes.
@MainActor
@Observable
final class TabSessionStore {
    private var sessions: [Tab.ID: TabSession] = [:]

    /// How many sessions were ever created, for the lazy-restore check.
    @ObservationIgnored private(set) var createdCount = 0
    /// Called for each new session before it loads anything, so callbacks are in place for the
    /// first title and URL.
    @ObservationIgnored var didCreate: ((Tab.ID, TabSession) -> Void)?

    var liveTabIDs: Set<Tab.ID> { Set(sessions.keys) }

    /// The session if the tab has one; never creates it.
    func existingSession(for id: Tab.ID) -> TabSession? { sessions[id] }

    /// The tab's session, created and pointed at the tab's URL on first use.
    func session(for tab: Tab) -> TabSession {
        if let existing = sessions[tab.id] { return existing }
        let session = TabSession()
        createdCount += 1
        didCreate?(tab.id, session)
        sessions[tab.id] = session
        if let url = tab.url { session.load(url) }
        return session
    }

    /// Drops the sessions of tabs that no longer exist.
    func releaseSessions(keeping ids: Set<Tab.ID>) {
        guard sessions.keys.contains(where: { !ids.contains($0) }) else { return }
        sessions = sessions.filter { ids.contains($0.key) }
    }
}
