#if DEBUG
import AppKit
import ArcXCore

/// What the app hands the self-test: the window, and how the session was loaded and is saved.
struct SelfTestContext {
    let controller: BrowserWindowController
    let loaded: SessionStore.LoadResult
    let store: SessionStore
    let saver: SessionSaver
    let startPage: URL?
    /// Runs the app's own termination path (which flushes the session) without quitting.
    let terminate: @MainActor () -> Void
}

/// An in-process smoke test, run with `ARCX_SELFTEST=<output dir>` (see `Scripts/selftest.sh`).
///
/// It drives the real window, `BrowserState` and the tab sessions against local fixture pages
/// written into the output directory (never the network), renders pages and the window to PNG
/// files, and writes `result-<phase>.txt`: one line per check and a final
/// `RESULT pass=N fail=N skip=N`. The process exits non-zero on any failure.
///
/// One launch runs one phase (`ARCX_SELFTEST_PHASE`), so relaunching can be tested:
/// - `main`: first launch, then everything about tabs, the sidebar and saving;
/// - `restore`: a second launch on the same data folder restores the session lazily;
/// - `corrupt`: a launch on a corrupt `session.json` sets it aside and starts fresh.
@MainActor
enum SelfTest {
    static func run(_ context: SelfTestContext, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let run = SelfTestRun(context: context, output: output, phase: TestHost.selfTestPhase)
        switch run.phase {
        case "main": await MainPhase(run).perform()
        case "restore": await RestorePhase(run).perform()
        case "corrupt": await CorruptPhase(run).perform()
        default: run.check(false, "unknown self-test phase '\(run.phase)'")
        }

        if let problem = TestHost.savedWindowProblem() {
            run.check(false, problem)
        } else {
            run.check(true, "a test run does not restore or save the window")
        }
        if TestHost.focusTakenCount > 0 {
            run.note("macOS made the background app active \(TestHost.focusTakenCount) time(s); it gave focus straight back")
        }
        run.finish()
    }
}

/// The log and the helpers every phase uses.
@MainActor
final class SelfTestRun {
    let context: SelfTestContext
    let output: URL
    let phase: String
    let fixtures: Fixtures.Files
    private var log: [String] = []
    private var passed = 0, failed = 0, skipped = 0

    var controller: BrowserWindowController { context.controller }
    var state: BrowserState { controller.state }
    var sessions: TabSessionStore { controller.sessions }

    init(context: SelfTestContext, output: URL, phase: String) {
        self.context = context
        self.output = output
        self.phase = phase
        fixtures = Fixtures.Files(output: output)
    }

    func check(_ condition: Bool, _ what: String) {
        log.append((condition ? "ok   " : "FAIL ") + what)
        if condition { passed += 1 } else { failed += 1 }
    }

    func note(_ what: String) { log.append("note \(what)") }

    /// Some behaviour only happens when the app has keyboard focus. A run in the background never
    /// takes focus, so such checks are skipped and listed, never passed silently.
    /// Wrap them as `if run.needsFocus("what is checked") { ... }`.
    func needsFocus(_ what: String) -> Bool {
        if NSApp.isActive { return true }
        log.append("skip \(what): needs keyboard focus; run ARCX_FOREGROUND=1 Scripts/selftest.sh")
        skipped += 1
        return false
    }

    /// Writes `result-<phase>.txt` and ends the process: status 0 only if nothing failed.
    func finish() -> Never {
        log.append("RESULT pass=\(passed) fail=\(failed) skip=\(skipped)")
        try? (log.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("result-\(phase).txt"),
                                                         atomically: true, encoding: .utf8)
        exit(failed == 0 ? 0 : 1)
    }

    /// Waits for a condition instead of guessing a delay, so the test is not timing-sensitive.
    func waitFor(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    func settled(_ session: TabSession, at url: URL? = nil, title: String) async -> Bool {
        await waitFor {
            !session.isLoading && session.title == title && (url == nil || samePage(session.url, url))
        }
    }

    func javaScript(_ session: TabSession, _ body: String) async -> String? {
        do { return try await session.callJavaScript(body) as? String } catch {
            note("JavaScript failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Renders a page through WebKit, writes `<name>.png` and returns its pixels for checks.
    func snapshot(_ session: TabSession, _ name: String) async -> Pixels? {
        do {
            let image = try await session.snapshot()
            guard let pixels = Pixels(image) else { check(false, "\(name): the snapshot has no bitmap"); return nil }
            try pixels.png().write(to: output.appendingPathComponent("\(name).png"))
            return pixels
        } catch {
            check(false, "\(name): snapshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Renders the whole window (see `WindowPicture`), writes `<name>.png` and returns it.
    func windowSnapshot(_ name: String) async -> WindowPicture? {
        // Let SwiftUI and AppKit finish any pending update before drawing.
        try? await Task.sleep(for: .milliseconds(150))
        do {
            let picture = try await WindowPicture.capture(controller)
            try picture.pixels.png().write(to: output.appendingPathComponent("\(name).png"))
            return picture
        } catch {
            check(false, "\(name): window snapshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The session file as it is on disk now, if it decodes. Read directly rather than through
    /// `SessionStore.load()`, which would set an unreadable file aside.
    func savedSnapshot() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: context.store.fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Waits until the debounced save has caught up and the file matches the state.
    func sessionFileMatchesState(_ seconds: Double = 5) async -> Bool {
        await waitFor(seconds) { !context.saver.hasPendingSave && savedSnapshot() == state.snapshot }
    }

    /// The page view on show is the selected tab's session's view.
    func showsSelectedTab() -> Bool {
        guard let id = state.selectedTabID, let session = sessions.existingSession(for: id) else { return false }
        return controller.container.content === session.view && session.view.superview === controller.container
    }

    var expectedSessionFile: URL { output.appendingPathComponent("expected-session.json") }
}
#endif
