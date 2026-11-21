import Foundation

/// Saves the session shortly after it changes, and at once on ``flush()``.
///
/// The first change after a save starts a timer of `delay`; every change until it fires rides
/// along with that one save. The timer is not pushed back by further changes, so a page that keeps
/// retitling itself cannot hold off saving forever. `flush()` writes a pending save immediately
/// and synchronously, for app termination.
///
/// It listens through ``BrowserState/observeChanges(_:)``, which fires for every real mutation,
/// so it never depends on Observation tracking being re-armed.
@MainActor
public final class SessionSaver {
    /// How many snapshots were written.
    public private(set) var saveCount = 0
    /// The error from the most recent write, cleared by a successful one.
    public private(set) var lastError: (any Error)?
    /// True between a change and the save that covers it.
    public var hasPendingSave: Bool { pending != nil }

    private let state: BrowserState
    private let delay: Duration
    private let write: @MainActor (SessionSnapshot) throws -> Void
    private var pending: Task<Void, Never>?

    public init(state: BrowserState, delay: Duration = .milliseconds(500),
                write: @escaping @MainActor (SessionSnapshot) throws -> Void) {
        self.state = state
        self.delay = delay
        self.write = write
        state.observeChanges { [weak self] _ in self?.setNeedsSave() }
    }

    public convenience init(state: BrowserState, store: SessionStore, delay: Duration = .milliseconds(500)) {
        self.init(state: state, delay: delay) { try store.save($0) }
    }

    /// Schedules a save unless one is already pending.
    public func setNeedsSave() {
        guard pending == nil else { return }
        let delay = delay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes a pending save now. Does nothing when there is none.
    public func flush() {
        guard pending != nil else { return }
        saveNow()
    }

    private func saveNow() {
        pending?.cancel()
        pending = nil
        do {
            try write(state.snapshot)
            saveCount += 1
            lastError = nil
        } catch {
            lastError = error
        }
    }
}
