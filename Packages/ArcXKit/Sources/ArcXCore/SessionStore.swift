import Foundation

/// What `session.json` holds: the open tabs and which one is selected.
public struct SessionSnapshot: Codable, Sendable, Hashable {
    /// The format this build reads and writes. A file with any other version is set aside.
    public static let currentVersion = 1

    public var version: Int
    public var tabs: [Tab]
    public var selectedTabID: Tab.ID?

    public init(version: Int = SessionSnapshot.currentVersion, tabs: [Tab], selectedTabID: Tab.ID?) {
        self.version = version
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }
}

/// Reads and writes the session file at a URL it is given.
///
/// Saving is atomic (write to a temporary file, then rename), so a crash mid-save leaves the
/// previous session intact. A file that cannot be read as a version-1 session, whether corrupt,
/// truncated or written by a newer build, is never overwritten: it is renamed to
/// `<name>.corrupt-<UTC timestamp>.<ext>` next to the original and the app starts fresh.
public struct SessionStore: Sendable {
    public enum LoadResult: Sendable, Hashable {
        /// No file: nothing has been saved yet.
        case firstLaunch
        case restored(SessionSnapshot)
        /// The file was unusable. `movedTo` is where it was set aside (nil if even that failed).
        case unreadable(reason: String, movedTo: URL?)
    }

    public let fileURL: URL
    private let now: @Sendable () -> Date

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    public func load() -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .firstLaunch
        } catch {
            return setAside("the file could not be read: \(error.localizedDescription)")
        }

        struct Header: Decodable { let version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            return setAside("not a session file")
        }
        guard header.version == SessionSnapshot.currentVersion else {
            return setAside("unknown version \(header.version)")
        }
        do {
            return .restored(try JSONDecoder().decode(SessionSnapshot.self, from: data))
        } catch {
            return setAside("the session does not decode: \(error)")
        }
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    // MARK: - Setting a bad file aside

    private func setAside(_ reason: String) -> LoadResult {
        let manager = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        let directory = fileURL.deletingLastPathComponent()
        let base = "\(stem).corrupt-\(formatter.string(from: now()))"

        for attempt in 0..<100 {
            let name = (attempt == 0 ? base : "\(base)-\(attempt)") + (ext.isEmpty ? "" : ".\(ext)")
            let destination = directory.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) { continue }
            do {
                try manager.moveItem(at: fileURL, to: destination)
                return .unreadable(reason: reason, movedTo: destination)
            } catch {
                return .unreadable(reason: "\(reason); setting it aside failed: \(error.localizedDescription)", movedTo: nil)
            }
        }
        return .unreadable(reason: "\(reason); no free name to set it aside", movedTo: nil)
    }
}
