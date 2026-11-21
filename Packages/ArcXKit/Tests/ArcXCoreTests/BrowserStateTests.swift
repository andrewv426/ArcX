import ArcXCore
import Foundation
import Testing

@MainActor
@Suite("BrowserState")
struct BrowserStateTests {
    private let a = URL(string: "https://a.example/")!
    private let b = URL(string: "https://b.example/")!
    private let c = URL(string: "https://c.example/")!
    private let d = URL(string: "https://d.example/")!

    /// A state with tabs on a, b, c (in that order) and the given one selected, plus a log of the
    /// changes it reports from here on.
    private func make(selecting index: Int = 0) -> (BrowserState, [Tab.ID], ChangeLog) {
        let tabs = [a, b, c].map { Tab(url: $0) }
        let state = BrowserState(tabs: tabs, selectedTabID: tabs[index].id)
        let log = ChangeLog()
        state.observeChanges { log.changes.append($0) }
        return (state, tabs.map(\.id), log)
    }

    @MainActor
    final class ChangeLog {
        var changes: [BrowserState.Change] = []
    }

    // MARK: Tab

    @Test("display title: title, else host, else New Tab")
    func displayTitle() {
        #expect(Tab(url: a, title: "Hello").displayTitle == "Hello")
        #expect(Tab(url: a, title: "  ").displayTitle == "a.example")
        #expect(Tab(url: nil).displayTitle == "New Tab")
        #expect(Tab(url: URL(fileURLWithPath: "/tmp/x.html")).displayTitle == "New Tab")
    }

    // MARK: Initial state

    @Test("an empty state has no selection")
    func empty() {
        let state = BrowserState()
        #expect(state.tabs.isEmpty)
        #expect(state.selectedTabID == nil)
        #expect(state.selectedTab == nil)
    }

    @Test("init repairs a selection that names no tab and drops duplicate IDs")
    func initRepairs() {
        let first = Tab(url: a), second = Tab(url: b)
        let state = BrowserState(tabs: [first, second, first], selectedTabID: UUID())
        #expect(state.tabs.map(\.id) == [first.id, second.id])
        #expect(state.selectedTabID == first.id)
        #expect(BrowserState(tabs: [], selectedTabID: UUID()).selectedTabID == nil)
    }

    // MARK: Adding

    @Test("adding a selected tab appends it and selects it")
    func addSelected() {
        let (state, ids, log) = make()
        let new = state.addTab(url: d)
        #expect(state.tabs.map(\.id) == ids + [new])
        #expect(state.selectedTabID == new)
        #expect(state.selectedTab?.url == d)
        #expect(log.changes == [[.tabs, .selection]])
    }

    @Test("adding a background tab after another inserts it there and keeps the selection")
    func addAfter() {
        let (state, ids, log) = make()
        let new = state.addTab(url: d, selected: false, after: ids[0])
        #expect(state.tabs.map(\.id) == [ids[0], new, ids[1], ids[2]])
        #expect(state.selectedTabID == ids[0])
        #expect(log.changes == [.tabs])
    }

    @Test("adding after an unknown tab appends")
    func addAfterUnknown() {
        let (state, ids, _) = make()
        let new = state.addTab(url: d, selected: false, after: UUID())
        #expect(state.tabs.map(\.id) == ids + [new])
    }

    @Test("an unselected tab added to an empty state is selected anyway")
    func addToEmpty() {
        let state = BrowserState()
        let new = state.addTab(url: a, selected: false)
        #expect(state.selectedTabID == new)
    }

    // MARK: Closing

    @Test("closing the selected tab selects the one below it")
    func closeSelectsBelow() {
        let (state, ids, log) = make(selecting: 1)
        state.closeTab(ids[1])
        #expect(state.tabs.map(\.id) == [ids[0], ids[2]])
        #expect(state.selectedTabID == ids[2])
        #expect(log.changes == [[.tabs, .selection]])
    }

    @Test("closing the selected last tab selects the one above it")
    func closeSelectsAbove() {
        let (state, ids, _) = make(selecting: 2)
        state.closeTab(ids[2])
        #expect(state.selectedTabID == ids[1])
    }

    @Test("closing an unselected tab keeps the selection")
    func closeUnselected() {
        let (state, ids, log) = make(selecting: 2)
        state.closeTab(ids[0])
        #expect(state.tabs.map(\.id) == [ids[1], ids[2]])
        #expect(state.selectedTabID == ids[2])
        #expect(log.changes == [.tabs])
    }

    @Test("closing the only tab leaves zero tabs and no selection, and no tab is created")
    func closeLast() {
        let only = Tab(url: a)
        let state = BrowserState(tabs: [only])
        state.closeTab(only.id)
        #expect(state.tabs.isEmpty)
        #expect(state.selectedTabID == nil)
    }

    @Test("closing an unknown tab changes nothing")
    func closeUnknown() {
        let (state, ids, log) = make()
        state.closeTab(UUID())
        #expect(state.tabs.map(\.id) == ids)
        #expect(state.recentlyClosed.isEmpty)
        #expect(log.changes.isEmpty)
    }

    // MARK: Reopening

    @Test("reopen puts the last closed tab back at its position and selects it")
    func reopen() {
        let (state, ids, _) = make(selecting: 0)
        state.updateTab(ids[1], title: "Bee")
        state.closeTab(ids[1])
        let reopened = state.reopenLastClosedTab()
        #expect(reopened == ids[1])
        #expect(state.tabs.map(\.id) == ids)
        #expect(state.tabs[1].title == "Bee")
        #expect(state.selectedTabID == ids[1])
        #expect(state.recentlyClosed.isEmpty)
    }

    @Test("reopen works in reverse closing order")
    func reopenOrder() {
        let (state, ids, _) = make()
        state.closeTab(ids[0])
        state.closeTab(ids[2])
        #expect(state.reopenLastClosedTab() == ids[2])
        #expect(state.reopenLastClosedTab() == ids[0])
        #expect(state.tabs.map(\.id) == ids)
    }

    @Test("reopen with fewer tabs left puts it at the end")
    func reopenClamps() {
        let (state, ids, _) = make()
        state.closeTab(ids[2])
        state.closeTab(ids[1])
        state.closeTab(ids[0])
        #expect(state.tabs.isEmpty)
        #expect(state.reopenLastClosedTab() == ids[0])
        #expect(state.reopenLastClosedTab() == ids[1])
        #expect(state.tabs.map(\.id) == [ids[0], ids[1]])
    }

    @Test("reopen with nothing closed returns nil and changes nothing")
    func reopenNothing() {
        let (state, ids, log) = make()
        #expect(state.reopenLastClosedTab() == nil)
        #expect(state.tabs.map(\.id) == ids)
        #expect(log.changes.isEmpty)
    }

    @Test("the closed-tab stack is bounded, dropping the oldest")
    func closedLimit() {
        let tabs = (0..<5).map { Tab(url: URL(string: "https://\($0).example/")!) }
        let state = BrowserState(tabs: tabs, closedTabLimit: 3)
        for tab in tabs { state.closeTab(tab.id) }
        #expect(state.recentlyClosed.map(\.tab.id) == tabs[2...].map(\.id))
    }

    // MARK: Selecting

    @Test("select changes the selection; selecting the selected tab or an unknown one is a no-op")
    func select() {
        let (state, ids, log) = make()
        state.select(ids[2])
        #expect(state.selectedTabID == ids[2])
        state.select(ids[2])
        state.select(UUID())
        #expect(state.selectedTabID == ids[2])
        #expect(log.changes == [.selection])
    }

    @Test("next and previous follow sidebar order and wrap")
    func nextPrevious() {
        let (state, ids, _) = make(selecting: 0)
        state.selectNextTab()
        #expect(state.selectedTabID == ids[1])
        state.selectNextTab()
        state.selectNextTab()
        #expect(state.selectedTabID == ids[0])
        state.selectPreviousTab()
        #expect(state.selectedTabID == ids[2])
        state.moveTab(ids[2], to: 0)
        state.selectNextTab()
        #expect(state.selectedTabID == ids[0])
    }

    @Test("next and previous with no tabs or one tab change nothing")
    func nextPreviousEdge() {
        let empty = BrowserState()
        empty.selectNextTab()
        empty.selectPreviousTab()
        #expect(empty.selectedTabID == nil)
        let one = Tab(url: a)
        let single = BrowserState(tabs: [one])
        single.selectNextTab()
        #expect(single.selectedTabID == one.id)
    }

    @Test("shortcut numbers 1 to 8 select that tab, 9 the last")
    func shortcutNumbers() {
        let (state, ids, _) = make(selecting: 0)
        #expect(state.selectTab(atShortcutNumber: 2))
        #expect(state.selectedTabID == ids[1])
        #expect(state.selectTab(atShortcutNumber: 9))
        #expect(state.selectedTabID == ids[2])
        #expect(state.selectTab(atShortcutNumber: 1))
        #expect(state.selectedTabID == ids[0])
    }

    @Test("shortcut numbers out of range change nothing", arguments: [0, 4, 8, 10, -1])
    func shortcutOutOfRange(_ number: Int) {
        let (state, ids, log) = make(selecting: 1)
        #expect(!state.selectTab(atShortcutNumber: number))
        #expect(state.selectedTabID == ids[1])
        #expect(log.changes.isEmpty)
    }

    @Test("9 on an empty state does nothing")
    func shortcutEmpty() {
        #expect(!BrowserState().selectTab(atShortcutNumber: 9))
    }

    // MARK: Moving

    @Test("move puts a tab at the final index, clamped")
    func move() {
        let (state, ids, log) = make()
        state.moveTab(ids[0], to: 2)
        #expect(state.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
        state.moveTab(ids[0], to: -5)
        #expect(state.tabs.map(\.id) == ids)
        state.moveTab(ids[1], to: 99)
        #expect(state.tabs.map(\.id) == [ids[0], ids[2], ids[1]])
        #expect(log.changes == [.tabs, .tabs, .tabs])
        #expect(state.selectedTabID == ids[0])
    }

    @Test("moving a tab to its own index is a no-op")
    func moveSame() {
        let (state, ids, log) = make()
        state.moveTab(ids[1], to: 1)
        state.moveTab(UUID(), to: 0)
        #expect(state.tabs.map(\.id) == ids)
        #expect(log.changes.isEmpty)
    }

    @Test("onMove offsets follow SwiftUI's rules", arguments: [
        ([0], 3, [1, 2, 0]),
        ([2], 0, [2, 0, 1]),
        ([0], 2, [1, 0, 2]),
        ([0, 2], 2, [1, 0, 2]),
        ([1], 1, [0, 1, 2]),
        ([1], 2, [0, 1, 2]),
        ([7], 0, [0, 1, 2]),
    ])
    func moveOffsets(_ source: [Int], _ destination: Int, _ expected: [Int]) {
        let (state, ids, _) = make()
        state.moveTabs(fromOffsets: IndexSet(source), toOffset: destination)
        #expect(state.tabs.map(\.id) == expected.map { ids[$0] })
    }

    // MARK: Engine updates

    @Test("updates from the engine change title and URL; the same values again do not notify")
    func update() {
        let (state, ids, log) = make()
        state.updateTab(ids[1], title: "Bee", url: d)
        #expect(state.tabs[1].title == "Bee")
        #expect(state.tabs[1].url == d)
        state.updateTab(ids[1], title: "Bee", url: d)
        state.updateTab(ids[1], title: "Bee")
        state.updateTab(ids[1])
        state.updateTab(UUID(), title: "Nobody")
        #expect(log.changes == [.content])
        state.updateTab(ids[1], url: a)
        #expect(state.tabs[1].title == "Bee")
        #expect(log.changes == [.content, .content])
    }

    // MARK: Snapshots

    @Test("a snapshot round-trips through JSON and back into a state")
    func snapshotRoundTrip() throws {
        let (state, ids, _) = make(selecting: 2)
        state.updateTab(ids[0], title: "Ünïcode ✓ \"quoted\"")
        let data = try JSONEncoder().encode(state.snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(decoded == state.snapshot)
        #expect(decoded.version == 1)
        let restored = BrowserState(snapshot: decoded)
        #expect(restored.tabs == state.tabs)
        #expect(restored.selectedTabID == ids[2])
        #expect(restored.recentlyClosed.isEmpty)
    }

    @Test("a snapshot with a dangling selection is repaired")
    func snapshotRepair() {
        let tabs = [Tab(url: a), Tab(url: b)]
        let restored = BrowserState(snapshot: SessionSnapshot(tabs: tabs, selectedTabID: UUID()))
        #expect(restored.selectedTabID == tabs[0].id)
        let empty = BrowserState(snapshot: SessionSnapshot(tabs: [], selectedTabID: UUID()))
        #expect(empty.selectedTabID == nil)
    }

    // MARK: Launch

    @Test("first launch opens one tab on the start page")
    func launchFirst() {
        let state = BrowserState.launching(from: .firstLaunch, startPage: a)
        #expect(state.tabs.map(\.url) == [a])
        #expect(state.selectedTabID == state.tabs.first?.id)
    }

    @Test("an unreadable session starts fresh like a first launch")
    func launchUnreadable() {
        let state = BrowserState.launching(from: .unreadable(reason: "x", movedTo: nil), startPage: a)
        #expect(state.tabs.map(\.url) == [a])
    }

    @Test("a restored session is used as saved, even with zero tabs")
    func launchRestored() {
        let tabs = [Tab(url: b), Tab(url: c)]
        let state = BrowserState.launching(from: .restored(SessionSnapshot(tabs: tabs, selectedTabID: tabs[1].id)), startPage: a)
        #expect(state.tabs == tabs)
        #expect(state.selectedTabID == tabs[1].id)
        let empty = BrowserState.launching(from: .restored(SessionSnapshot(tabs: [], selectedTabID: nil)), startPage: a)
        #expect(empty.tabs.isEmpty)
    }

    @Test("a start URL opens as an additional selected tab")
    func launchStartURL() {
        let first = BrowserState.launching(from: .firstLaunch, startPage: a, startURL: d)
        #expect(first.tabs.map(\.url) == [a, d])
        #expect(first.selectedTab?.url == d)
        let tabs = [Tab(url: b)]
        let restored = BrowserState.launching(from: .restored(SessionSnapshot(tabs: tabs, selectedTabID: tabs[0].id)), startPage: a, startURL: d)
        #expect(restored.tabs.map(\.url) == [b, d])
        #expect(restored.selectedTab?.url == d)
    }
}
