#if DEBUG
import AppKit
import ArcXCore

/// The second launch, on the data folder the `main` phase left: the session comes back as it was
/// saved, only the selected tab gets a web view, and the others get one when first selected.
@MainActor
struct RestorePhase {
    let run: SelfTestRun
    init(_ run: SelfTestRun) { self.run = run }

    func perform() async {
        let state = run.state, sessions = run.sessions
        guard let data = try? Data(contentsOf: run.expectedSessionFile),
              let expected = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else {
            run.check(false, "the main phase left expected-session.json")
            return
        }
        run.check(run.context.loaded == .restored(expected), "the second launch reads the saved session, got \(run.context.loaded)")
        run.check(state.snapshot == expected, "tabs, titles, URLs and the selection come back exactly as saved")
        guard let selected = expected.tabs.first(where: { $0.id == expected.selectedTabID }),
              let session = sessions.existingSession(for: selected.id) else {
            run.check(false, "the restored selection has a page")
            return
        }
        run.check(sessions.createdCount == 1 && sessions.liveTabIDs == [selected.id],
                  "only the selected tab got a web view (\(sessions.createdCount) created for \(state.tabs.count) tabs)")
        run.check(run.showsSelectedTab(), "the content pane shows the restored selection")
        let responder = run.controller.window?.firstResponder as? NSView
        run.check(responder?.isDescendant(of: session.view) == true,
                  "the restored page is the window's first responder, not the address field (\(responder.map { String(describing: type(of: $0)) } ?? "none"))")
        run.check(await run.settled(session, at: selected.url, title: selected.title),
                  "the selected tab loads its page: '\(session.title)'")
        run.check(await run.waitFor { run.controller.window?.title == selected.title }, "the window title follows the restored selection")

        // Unselected tabs show their saved titles in the sidebar with no web view behind them.
        run.check(state.snapshot == expected, "loading the selected page kept the saved titles (no blank title while loading)")
        let others = expected.tabs.filter { $0.id != selected.id }
        run.check(others.allSatisfy { sessions.existingSession(for: $0.id) == nil } && sessions.createdCount == 1,
                  "restored tabs the user has not selected still have no web view after the selected one loaded")
        run.check(abs(run.controller.sidebarWidth - 300) < 0.5,
                  "the sidebar opens at the width the last launch left (300 pt), got \(run.controller.sidebarWidth)")
        let problems = run.sidebarProblems()
        run.check(problems.isEmpty, "the restored sidebar lays out a row for every saved tab" + (problems.isEmpty ? "" : ": " + problems.joined(separator: "; ")))
        if let picture = await run.windowSnapshot("restore-window") {
            let ink = picture.pixels.inkCount(in: picture.sidebar)
            run.check(ink >= 400, "the restored sidebar's capture is drawn: \(ink) px of text and controls")
        }

        if let other = others.first {
            state.select(other.id)
            if let opened = sessions.existingSession(for: other.id) {
                run.check(sessions.createdCount == 2, "selecting a restored tab creates its web view then")
                run.check(await run.settled(opened, at: other.url, title: other.title), "and loads its saved URL: '\(opened.title)'")
            } else {
                run.check(false, "selecting a restored tab creates its web view")
            }
        }
    }
}

/// A launch on a corrupt `session.json` (written by `Scripts/selftest.sh`, with `ARCX_START_URL`
/// set): the file is moved aside unchanged, the app starts fresh and saves a good session.
@MainActor
struct CorruptPhase {
    let run: SelfTestRun
    init(_ run: SelfTestRun) { self.run = run }

    func perform() async {
        let state = run.state, sessions = run.sessions
        let original = try? Data(contentsOf: run.output.appendingPathComponent("corrupt-session.txt"))
        guard case .unreadable(let reason, let movedTo?) = run.context.loaded else {
            run.check(false, "a corrupt session.json is reported and set aside, got \(run.context.loaded)")
            return
        }
        run.check(movedTo.deletingLastPathComponent().standardizedFileURL == AppPaths.dataDirectory.standardizedFileURL
                  && movedTo.lastPathComponent.hasPrefix("session.corrupt-") && movedTo.pathExtension == "json",
                  "the corrupt file is moved aside next to it as \(movedTo.lastPathComponent) (\(reason))")
        run.check(original != nil && (try? Data(contentsOf: movedTo)) == original, "the moved file is byte for byte what was there")

        let startPage = run.context.startPage
        run.check(state.tabs.count == 2 && samePage(state.tabs.first?.url, startPage) && samePage(state.tabs.last?.url, run.fixtures.pageA),
                  "the app starts fresh: the start page plus ARCX_START_URL as an extra tab")
        run.check(state.selectedTabID == state.tabs.last?.id, "the ARCX_START_URL tab is selected")
        if let id = state.selectedTabID, let session = sessions.existingSession(for: id) {
            run.check(await run.settled(session, at: run.fixtures.pageA, title: "Fixture A"), "it loads")
        } else {
            run.check(false, "the ARCX_START_URL tab has a page")
        }
        run.check(sessions.createdCount == 1, "the unselected start page tab has no web view")
        run.check(await run.sessionFileMatchesState(), "a fresh session.json is written and matches the state")
    }
}
#endif
