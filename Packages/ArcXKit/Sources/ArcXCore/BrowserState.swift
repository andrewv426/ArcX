import Foundation
import Observation

/// The single source of truth for which tabs exist, their order and which one is selected.
///
/// Views read it through Observation. Everything that must react to every change, such as the
/// session saver and the window's tab coordinator, registers with ``observeChanges(_:)`` instead:
/// every mutation runs through one path that compares the old and new values, writes only what
/// differs and then calls each change handler once. A mutation that changes nothing (the same
/// title again, a move to the same place) calls nobody.
///
/// Invariant: `selectedTabID` is nil exactly when there are no tabs. Zero tabs is a valid state.
@MainActor
@Observable
public final class BrowserState {
    /// What a mutation changed. Handlers get all the kinds one mutation produced, at once.
    public struct Change: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Tabs were added, removed or reordered.
        public static let tabs = Change(rawValue: 1 << 0)
        /// A tab's title or URL changed, with the same tabs in the same order.
        public static let content = Change(rawValue: 1 << 1)
        /// A different tab, or none, is selected.
        public static let selection = Change(rawValue: 1 << 2)
    }

    /// A closed tab and where it was, so reopening puts it back in place.
    public struct ClosedTab: Sendable, Hashable {
        public let tab: Tab
        public let index: Int
    }

    public private(set) var tabs: [Tab] = []
    public private(set) var selectedTabID: Tab.ID?
    /// Most recently closed last. In memory only; bounded by `closedTabLimit`.
    public private(set) var recentlyClosed: [ClosedTab] = []

    @ObservationIgnored public let closedTabLimit: Int
    @ObservationIgnored private var changeHandlers: [@MainActor (Change) -> Void] = []

    /// Duplicate tab IDs are dropped (the first wins) and a selection that names no tab is
    /// replaced by the first tab, so any input gives a valid state.
    public init(tabs: [Tab] = [], selectedTabID: Tab.ID? = nil, closedTabLimit: Int = 25) {
        var seen = Set<Tab.ID>()
        let unique = tabs.filter { seen.insert($0.id).inserted }
        self.tabs = unique
        self.selectedTabID = selectedTabID.flatMap { id in seen.contains(id) ? id : nil } ?? unique.first?.id
        self.closedTabLimit = max(0, closedTabLimit)
    }

    public convenience init(snapshot: SessionSnapshot, closedTabLimit: Int = 25) {
        self.init(tabs: snapshot.tabs, selectedTabID: snapshot.selectedTabID, closedTabLimit: closedTabLimit)
    }

    /// The state the app opens with, given what the session store found.
    ///
    /// A restored session is used as saved, even with zero tabs. A first launch, or a file that
    /// could not be read, starts with one tab on `startPage`. `startURL` (from `ARCX_START_URL`)
    /// opens as an additional, selected tab either way.
    public static func launching(from loaded: SessionStore.LoadResult, startPage: URL?, startURL: URL? = nil) -> BrowserState {
        let state: BrowserState
        switch loaded {
        case .restored(let snapshot):
            state = BrowserState(snapshot: snapshot)
        case .firstLaunch, .unreadable:
            state = BrowserState()
            state.addTab(url: startPage)
        }
        if let startURL { state.addTab(url: startURL) }
        return state
    }

    // MARK: - Reading

    public var selectedTab: Tab? { selectedTabID.flatMap(tab(_:)) }

    public func tab(_ id: Tab.ID) -> Tab? { tabs.first { $0.id == id } }

    public func index(of id: Tab.ID) -> Int? { tabs.firstIndex { $0.id == id } }

    public var snapshot: SessionSnapshot { SessionSnapshot(tabs: tabs, selectedTabID: selectedTabID) }

    /// Calls `handler` after every mutation that changed something, for the life of this state.
    public func observeChanges(_ handler: @escaping @MainActor (Change) -> Void) {
        changeHandlers.append(handler)
    }

    // MARK: - Mutations

    /// Adds a tab at the end, or right after `anchor` when that tab exists, and returns its ID.
    /// An unselected tab added to an empty window is selected anyway, to keep the invariant.
    @discardableResult
    public func addTab(url: URL?, title: String = "", selected: Bool = true, after anchor: Tab.ID? = nil) -> Tab.ID {
        let tab = Tab(url: url, title: title)
        mutate { tabs, selection in
            let index = anchor.flatMap { id in tabs.firstIndex { $0.id == id } }.map { $0 + 1 } ?? tabs.endIndex
            tabs.insert(tab, at: index)
            if selected { selection = tab.id }
        }
        return tab.id
    }

    /// Closes a tab and remembers it for ``reopenLastClosedTab()``. Closing the selected tab
    /// selects the one below it, else the one above. Closing the last tab leaves none.
    public func closeTab(_ id: Tab.ID) {
        guard let index = index(of: id) else { return }
        recentlyClosed.append(ClosedTab(tab: tabs[index], index: index))
        if recentlyClosed.count > closedTabLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - closedTabLimit)
        }
        mutate { tabs, selection in
            tabs.remove(at: index)
            if selection == id {
                selection = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            }
        }
    }

    /// Puts the most recently closed tab back where it was (or at the end, if fewer tabs remain)
    /// and selects it. Returns its ID, or nil when nothing was closed.
    @discardableResult
    public func reopenLastClosedTab() -> Tab.ID? {
        guard let closed = recentlyClosed.popLast() else { return nil }
        var tab = closed.tab
        if index(of: tab.id) != nil { tab = Tab(url: tab.url, title: tab.title) }
        mutate { tabs, selection in
            tabs.insert(tab, at: min(closed.index, tabs.count))
            selection = tab.id
        }
        return tab.id
    }

    public func select(_ id: Tab.ID) {
        guard index(of: id) != nil else { return }
        mutate { _, selection in selection = id }
    }

    /// Moves a tab so it ends up at `destination` (clamped to the list).
    public func moveTab(_ id: Tab.ID, to destination: Int) {
        guard let source = index(of: id) else { return }
        mutate { tabs, _ in
            let tab = tabs.remove(at: source)
            tabs.insert(tab, at: min(max(destination, 0), tabs.count))
        }
    }

    /// Moves tabs the way SwiftUI's `onMove` describes it: `destination` is an offset in the list
    /// before the move.
    public func moveTabs(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutate { tabs, _ in
            let valid = source.filter { tabs.indices.contains($0) }
            guard !valid.isEmpty else { return }
            let moving = valid.map { tabs[$0] }
            let target = min(max(destination, 0), tabs.count)
            let removedBefore = valid.filter { $0 < target }.count
            for index in valid.reversed() { tabs.remove(at: index) }
            tabs.insert(contentsOf: moving, at: target - removedBefore)
        }
    }

    /// The next tab in sidebar order, wrapping from the last to the first.
    public func selectNextTab() { selectAdjacent(by: 1) }

    /// The previous tab in sidebar order, wrapping from the first to the last.
    public func selectPreviousTab() { selectAdjacent(by: -1) }

    /// ⌘1…⌘9: 1 to 8 select that tab, 9 the last one. Returns false (and changes nothing) when
    /// there is no such tab.
    @discardableResult
    public func selectTab(atShortcutNumber number: Int) -> Bool {
        let index: Int
        switch number {
        case 1...8: index = number - 1
        case 9: index = tabs.count - 1
        default: return false
        }
        guard tabs.indices.contains(index) else { return false }
        select(tabs[index].id)
        return true
    }

    /// Records what the engine reports for a tab. Nil leaves that value as it is; the same value
    /// again is not a change.
    public func updateTab(_ id: Tab.ID, title: String? = nil, url: URL? = nil) {
        guard let index = index(of: id) else { return }
        mutate { tabs, _ in
            if let title { tabs[index].title = title }
            if let url { tabs[index].url = url }
        }
    }

    // MARK: - The one mutation path

    private func selectAdjacent(by step: Int) {
        guard !tabs.isEmpty else { return }
        let current = selectedTabID.flatMap(index(of:)) ?? 0
        let next = ((current + step) % tabs.count + tabs.count) % tabs.count
        select(tabs[next].id)
    }

    /// Applies `body` to copies of the tabs and selection, repairs the selection invariant, writes
    /// back only what differs and tells every handler what kind of change it was.
    private func mutate(_ body: (inout [Tab], inout Tab.ID?) -> Void) {
        var newTabs = tabs
        var newSelection = selectedTabID
        body(&newTabs, &newSelection)
        if let id = newSelection, !newTabs.contains(where: { $0.id == id }) { newSelection = nil }
        if newSelection == nil { newSelection = newTabs.first?.id }

        var change: Change = []
        if newTabs.map(\.id) != tabs.map(\.id) {
            change.insert(.tabs)
        } else if newTabs != tabs {
            change.insert(.content)
        }
        if newSelection != selectedTabID { change.insert(.selection) }
        guard !change.isEmpty else { return }

        if newTabs != tabs { tabs = newTabs }
        if newSelection != selectedTabID { selectedTabID = newSelection }
        for handler in changeHandlers { handler(change) }
    }
}
