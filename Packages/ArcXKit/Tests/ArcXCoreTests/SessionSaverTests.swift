import ArcXCore
import Foundation
import Testing

@MainActor
@Suite("SessionSaver")
struct SessionSaverTests {
    @MainActor
    final class Writes {
        var snapshots: [SessionSnapshot] = []
    }

    private func make(delay: Duration = .milliseconds(50)) -> (BrowserState, SessionSaver, Writes) {
        let state = BrowserState(tabs: [Tab(url: URL(string: "https://a.example/")!)])
        let writes = Writes()
        let saver = SessionSaver(state: state, delay: delay) { writes.snapshots.append($0) }
        return (state, saver, writes)
    }

    private func waitFor(_ seconds: Double = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("nothing is written without a change")
    func idle() async {
        let (_, saver, writes) = make()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(writes.snapshots.isEmpty)
        #expect(!saver.hasPendingSave)
    }

    @Test("many changes in a burst become one write of the final state")
    func coalesces() async {
        let (state, saver, writes) = make()
        let id = state.tabs[0].id
        for index in 0..<200 { state.updateTab(id, title: "Title \(index)") }
        state.addTab(url: URL(string: "https://b.example/")!)
        #expect(writes.snapshots.isEmpty, "nothing is written synchronously")
        #expect(saver.hasPendingSave)
        await waitFor { !writes.snapshots.isEmpty }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(writes.snapshots.count == 1)
        #expect(writes.snapshots.last == state.snapshot)
        #expect(saver.saveCount == 1)
        #expect(!saver.hasPendingSave)
    }

    @Test("a change after a save schedules another save")
    func secondBurst() async {
        let (state, saver, writes) = make()
        defer { withExtendedLifetime(saver) {} }
        state.addTab(url: nil)
        await waitFor { writes.snapshots.count == 1 }
        state.addTab(url: nil)
        await waitFor { writes.snapshots.count == 2 }
        #expect(writes.snapshots.count == 2)
        #expect(writes.snapshots.last?.tabs.count == 3)
    }

    @Test("no-op mutations do not schedule a save")
    func noOps() async {
        let (state, saver, writes) = make()
        let id = state.tabs[0].id
        state.select(id)
        state.moveTab(id, to: 0)
        state.updateTab(id, url: state.tabs[0].url)
        #expect(!saver.hasPendingSave)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(writes.snapshots.isEmpty)
    }

    @Test("flush writes a pending save at once, and the timer does not write it again")
    func flush() async {
        let (state, saver, writes) = make(delay: .seconds(10))
        state.addTab(url: nil)
        saver.flush()
        #expect(writes.snapshots == [state.snapshot])
        #expect(!saver.hasPendingSave)
        saver.flush()
        #expect(writes.snapshots.count == 1, "a second flush with nothing pending writes nothing")
    }

    @Test("flush with nothing pending writes nothing")
    func flushIdle() {
        let (_, saver, writes) = make()
        saver.flush()
        #expect(writes.snapshots.isEmpty)
    }

    @Test("a failed write is reported and the next change tries again")
    func failure() async {
        @MainActor final class Disk { var fail = true; var written = 0 }
        let state = BrowserState()
        let disk = Disk()
        let saver = SessionSaver(state: state, delay: .milliseconds(20)) { _ in
            if disk.fail { throw CocoaError(.fileWriteNoPermission) }
            disk.written += 1
        }
        state.addTab(url: nil)
        saver.flush()
        #expect(saver.lastError != nil)
        #expect(saver.saveCount == 0)
        disk.fail = false
        state.addTab(url: nil)
        saver.flush()
        #expect(saver.lastError == nil)
        #expect(disk.written == 1)
    }

    @Test("the store-backed saver writes session.json")
    func storeBacked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArcXSaver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(fileURL: directory.appendingPathComponent("session.json"))
        let state = BrowserState()
        let saver = SessionSaver(state: state, store: store, delay: .seconds(10))
        state.addTab(url: URL(string: "https://a.example/")!, title: "A")
        saver.flush()
        #expect(store.load() == .restored(state.snapshot))
    }
}
