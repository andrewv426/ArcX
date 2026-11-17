import ArcXCore
import Foundation
import Testing

@Suite("SessionStore")
struct SessionStoreTests {
    /// A fresh directory per test, removed afterwards.
    private final class Directory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArcXCoreTests-\(UUID().uuidString)", isDirectory: true)
        var session: URL { url.appendingPathComponent("session.json") }
        func contents() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

    private let sampleSnapshot: SessionSnapshot = {
        let tabs = [
            Tab(url: URL(string: "https://a.example/")!, title: "A"),
            Tab(url: URL(fileURLWithPath: "/tmp/with space.html"), title: ""),
            Tab(url: nil, title: "Blank"),
        ]
        return SessionSnapshot(tabs: tabs, selectedTabID: tabs[1].id)
    }()

    private func sample() -> SessionSnapshot { sampleSnapshot }

    @Test("a missing file is a first launch")
    func missing() {
        let dir = Directory()
        #expect(SessionStore(fileURL: dir.session).load() == .firstLaunch)
        #expect(dir.contents().isEmpty)
    }

    @Test("save creates the directory, and load reads back the same snapshot")
    func roundTrip() throws {
        let dir = Directory()
        let store = SessionStore(fileURL: dir.session)
        try store.save(sample())
        #expect(store.load() == .restored(sample()))
        #expect(dir.contents() == ["session.json"])
    }

    @Test("save replaces the previous file and leaves no temporary files")
    func overwrite() throws {
        let dir = Directory()
        let store = SessionStore(fileURL: dir.session)
        try store.save(sample())
        let second = SessionSnapshot(tabs: [], selectedTabID: nil)
        try store.save(second)
        #expect(store.load() == .restored(second))
        #expect(dir.contents() == ["session.json"])
    }

    @Test("the file carries version 1")
    func versionField() throws {
        let dir = Directory()
        try SessionStore(fileURL: dir.session).save(sample())
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.session)) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
    }

    @Test("a corrupt file is moved aside unchanged and the load starts fresh", arguments: [
        "{ not json",
        "",
        "[1, 2, 3]",
        #"{"version": 1, "tabs": "nope"}"#,
        #"{"version": 1, "tabs": [{"id": "not-a-uuid", "title": ""}]}"#,
    ])
    func corrupt(_ text: String) throws {
        let dir = Directory()
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.session)
        let store = SessionStore(fileURL: dir.session, now: { [fixedDate] in fixedDate })
        guard case .unreadable(_, let movedTo?) = store.load() else {
            Issue.record("expected the file to be set aside")
            return
        }
        #expect(movedTo.lastPathComponent == "session.corrupt-20270115T080000Z.json")
        #expect(try Data(contentsOf: movedTo) == Data(text.utf8))
        #expect(dir.contents() == ["session.corrupt-20270115T080000Z.json"])
        #expect(store.load() == .firstLaunch)
    }

    @Test("an unknown version is set aside, not overwritten", arguments: [0, 2, 99])
    func unknownVersion(_ version: Int) throws {
        let dir = Directory()
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        var snapshot = sample()
        snapshot.version = version
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: dir.session)
        let result = SessionStore(fileURL: dir.session).load()
        guard case .unreadable(let reason, let movedTo?) = result else {
            Issue.record("expected the file to be set aside, got \(result)")
            return
        }
        #expect(reason.contains("version \(version)"))
        #expect(try Data(contentsOf: movedTo) == data)
        #expect(!FileManager.default.fileExists(atPath: dir.session.path))
    }

    @Test("setting aside twice in the same second does not collide")
    func collision() throws {
        let dir = Directory()
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let store = SessionStore(fileURL: dir.session, now: { [fixedDate] in fixedDate })
        try Data("bad one".utf8).write(to: dir.session)
        _ = store.load()
        try Data("bad two".utf8).write(to: dir.session)
        guard case .unreadable(_, let second?) = store.load() else {
            Issue.record("expected the second file to be set aside")
            return
        }
        #expect(second.lastPathComponent == "session.corrupt-20270115T080000Z-1.json")
        #expect(dir.contents() == ["session.corrupt-20270115T080000Z-1.json", "session.corrupt-20270115T080000Z.json"])
    }
}
