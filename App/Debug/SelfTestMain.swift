#if DEBUG
import AppKit
import ArcXCore

/// The first launch: tabs, the sidebar, the address field, links that open tabs, saving, the
/// empty state and the window snapshots. It ends by leaving a known session on disk for the
/// `restore` phase.
@MainActor
struct MainPhase {
    let run: SelfTestRun
    init(_ run: SelfTestRun) { self.run = run }

    private var controller: BrowserWindowController { run.controller }
    private var state: BrowserState { run.state }
    private var sessions: TabSessionStore { run.sessions }
    private var files: Fixtures.Files { run.fixtures }
    private func check(_ condition: Bool, _ what: String) { run.check(condition, what) }

    func perform() async {
        do { try files.write() } catch { check(false, "write the fixture pages: \(error.localizedDescription)") }
        guard await launch() else { return }
        await navigation()
        await newTabAndAddress()
        await keepAlive()
        await windowPicture()
        await linksOpenTabs()
        await reorderAndSelect()
        await closeAndReopen()
        await collapsedSidebar()
        await emptyState()
        await leaveSessionForRestore()
    }

    // MARK: First launch

    private func launch() async -> Bool {
        let startPage = run.context.startPage
        check(startPage != nil, "the start page is bundled")
        check(run.context.loaded == .firstLaunch, "a fresh data folder is a first launch, got \(run.context.loaded)")
        check(state.tabs.count == 1 && samePage(state.tabs.first?.url, startPage) && state.selectedTabID == state.tabs.first?.id,
              "first launch opens one selected tab on the start page")
        check(AppPaths.dataDirectory.path.hasPrefix(run.output.path) && run.context.store.fileURL.path.hasPrefix(run.output.path),
              "a test run keeps its session inside the output folder: \(AppPaths.dataDirectory.path)")
        check(abs(controller.sidebarWidth - BrowserWindowController.defaultSidebarWidth) < 1,
              "the sidebar opens \(Int(BrowserWindowController.defaultSidebarWidth)) pt wide at the divider, got \(controller.sidebarWidth)")
        check(!controller.sidebarItem.isCollapsed && controller.container.topInset == 0,
              "with the sidebar shown, the page reaches the top of the window (inset \(controller.container.topInset))")
        check(controller.sidebarItem.behavior == .sidebar, "the sidebar is a system sidebar split item")

        guard let first = state.selectedTabID, let session = sessions.existingSession(for: first) else {
            check(false, "the selected tab has a session")
            return false
        }
        check(sessions.createdCount == 1 && run.showsSelectedTab(), "the content pane shows the selected tab's page")
        let responder = controller.window?.firstResponder as? NSView
        check(responder?.isDescendant(of: session.view) == true,
              "the page, not the address field, is the window's first responder at launch")
        let started = await run.settled(session, at: startPage, title: "ArcX")
        check(started, "the start page loads, got '\(session.title)' at \(session.url?.absoluteString ?? "nil")")
        check(!session.isLoading && session.estimatedProgress == 1, "loading ends: isLoading false, progress \(session.estimatedProgress)")
        check(!session.canGoBack && !session.canGoForward, "nothing to go back or forward to on launch")
        check(await run.waitFor { state.selectedTab?.title == "ArcX" }, "the page title reaches BrowserState")
        check(await run.waitFor { controller.window?.title == "ArcX" }, "the window title follows the selected tab")
        if let pixels = await run.snapshot(session, "01-start-page") {
            // Blank is 0 ink pixels. The page's 64 pt mark alone is over 4,000 px at 1x; its text adds more.
            let ink = pixels.inkCount()
            let share = Double(ink) / Double(pixels.width * pixels.height)
            check(pixels.width > 100 && pixels.height > 100 && ink >= 1_500 && share < 0.5,
                  "the start page snapshot is not blank: \(ink) px differ clearly from the background "
                  + "(\(pixels.width)×\(pixels.height) px; need at least 1,500 and under half)")
        }
        let agent = await run.javaScript(session, "return navigator.userAgent") ?? ""
        check(agent.contains("Safari/") && agent.contains("Version/"), "the user agent looks like Safari: \(agent)")
        check(!WebViewFactory.storesDataOnDisk, "web data is not persistent in a test run")
        check(AppDefaults.store !== UserDefaults.standard, "a test run uses its own preferences (\(TestHost.defaultsSuite))")
        let stored = AppDefaults.store.double(forKey: BrowserWindowController.sidebarWidthKey)
        check(stored == Double(controller.sidebarWidth.rounded()),
              "the sidebar width is remembered in the test preferences: \(stored), divider at \(controller.sidebarWidth)")
        return true
    }

    // MARK: Navigation in one tab

    private func navigation() async {
        guard let session = run.controller.tabs.selectedSession, let id = state.selectedTabID else { return }
        session.load(files.pageA)
        check(await run.settled(session, at: files.pageA, title: "Fixture A"), "a local page loads, got '\(session.title)'")
        check(await run.waitFor { state.tab(id)?.title == "Fixture A" && samePage(state.tab(id)?.url, files.pageA) },
              "the page's title and URL reach the tab in BrowserState")
        check(await run.waitFor { controller.window?.title == "Fixture A" }, "the window title follows the page")
        check(await run.javaScript(session, "return document.getElementById('js').textContent + '|' + (6 * 7)") == "JavaScript ran|42",
              "JavaScript runs in the page")
        check(session.canGoBack && !session.canGoForward, "after one navigation: can go back, not forward")
        if let pixels = await run.snapshot(session, "02-fixture-a") {
            let banner = pixels.share(of: (0x1E, 0x6F, 0xFF))
            check(banner > 0.25 && banner < 0.6, "the page is painted: its blue banner covers \(Int(banner * 100))% of the snapshot (expected 25–60%)")
        }

        session.load(files.pageB)
        check(await run.settled(session, at: files.pageB, title: "Fixture B"), "a second page loads")
        controller.navigateBack(nil)
        check(await run.settled(session, at: files.pageA, title: "Fixture A"), "Back returns to the first page")
        check(await run.waitFor { session.canGoBack && session.canGoForward }, "after going back: can go back (to the start page) and forward")
        check(controller.validateMenuItem(menuItem(#selector(BrowserWindowController.navigateForward(_:)))),
              "History > Forward is enabled after going back")
        controller.navigateForward(nil)
        check(await run.settled(session, at: files.pageB, title: "Fixture B"), "Forward returns to the second page")
        check(await run.waitFor { session.canGoBack && !session.canGoForward }, "after going forward: nothing further forward")
        check(!controller.validateMenuItem(menuItem(#selector(BrowserWindowController.navigateForward(_:)))),
              "History > Forward is disabled with nothing to go forward to")
        if let pixels = await run.snapshot(session, "03-fixture-b") {
            let block = pixels.share(of: (0xE6, 0x49, 0x80))
            check(block > 0.25, "the second page is painted: its pink block covers \(Int(block * 100))% of the snapshot")
        }
        check(await run.sessionFileMatchesState(), "session.json appears in the test data folder after a change and matches the state")
    }

    // MARK: New tab and the address field

    private func newTabAndAddress() async {
        let before = state.tabs.map(\.id)
        controller.newTab(nil)
        guard state.tabs.count == before.count + 1, let id = state.selectedTabID, !before.contains(id) else {
            check(false, "New Tab adds a tab and selects it")
            return
        }
        check(state.tabs.last?.id == id && samePage(state.selectedTab?.url, run.context.startPage),
              "New Tab adds a selected tab at the end, on the start page")
        check(sessions.createdCount == 2 && run.showsSelectedTab(), "the content pane shows the new tab's page")
        if let old = before.first.flatMap(sessions.existingSession(for:)) {
            check(old.view.superview == nil, "the previous tab's page left the view hierarchy (so WebKit throttles it)")
        }
        if run.needsFocus("New Tab puts the caret in the address field") {
            check(controller.addressField.isEditing, "New Tab puts the caret in the address field")
        }
        guard let session = sessions.existingSession(for: id) else { return }
        check(await run.settled(session, at: run.context.startPage, title: "ArcX"), "the new tab loads the start page")
        check(await run.waitFor { controller.addressField.text.isEmpty }, "the address field is empty on the start page")

        // The address field's submit path: typed text -> URLClassifier -> the selected tab.
        let typed = "  file://\(files.pageC.path)  "
        check(controller.submitAddress(typed), "a typed file:// path with a space is accepted")
        check(await run.settled(session, at: files.pageC, title: "Fixture C"), "it loads in the selected tab, got '\(session.title)'")
        check(state.tabs.count == before.count + 1, "submitting with a tab selected opens no new tab")
        check(await run.waitFor { controller.addressField.text == state.selectedTab?.url?.absoluteString && state.selectedTab?.title == "Fixture C" },
              "the address field and the tab follow the loaded page: '\(controller.addressField.text)'")
        check(controller.submitAddress("data:text/html,<title>Data fixture</title><p>from a data URL</p>"),
              "a typed data: URL is accepted")
        check(await run.settled(session, title: "Data fixture"), "a typed data: URL loads, got '\(session.title)'")
        check(!controller.submitAddress("   "), "blank text is not submitted")
        if run.needsFocus("⌘L focuses the address field and selects its text") {
            controller.openLocation(nil)
            let editor = controller.addressField.field?.currentEditor()
            check(editor != nil && editor?.selectedRange.length == controller.addressField.text.utf16.count,
                  "⌘L focuses the address field and selects its text")
            // Pressing Return through the field keeps the submitted URL displayed (no flash back)
            // and hands focus to the page; Escape restores the URL and returns focus to the page.
            if let field = controller.addressField.field, let textView = field.currentEditor() as? NSTextView {
                let beforeURL = controller.addressField.text
                textView.string = "  file://\(files.pageB.path)  "
                _ = field.delegate?.control?(field, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
                check(!controller.addressField.isEditing && controller.addressField.text == files.pageB.absoluteString,
                      "Return submits without flashing back to the previous URL: '\(controller.addressField.text)'")
                let responder = controller.window?.firstResponder as? NSView
                check(responder?.isDescendant(of: session.view) == true,
                      "Return hands keyboard focus back to the page")
                _ = await run.settled(session, at: files.pageB, title: "Fixture B")

                // Restore Data fixture so downstream checks see the expected page.
                check(controller.submitAddress(beforeURL), "re-submits the data: URL")
                _ = await run.settled(session, title: "Data fixture")

                controller.openLocation(nil)
                if let escapeEditor = field.currentEditor() as? NSTextView {
                    escapeEditor.string = "half-typed"
                    _ = field.delegate?.control?(field, textView: escapeEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
                    let afterEscape = controller.window?.firstResponder as? NSView
                    check(!controller.addressField.isEditing && controller.addressField.text == beforeURL
                          && afterEscape?.isDescendant(of: session.view) == true,
                          "Escape restores the URL and returns keyboard focus to the page")
                }

                // Switching tabs while editing the address field leaves editing and focuses the new page.
                controller.openLocation(nil)
                controller.selectPreviousTab(nil)
                let switchedResponder = controller.window?.firstResponder as? NSView
                let switchedPage = controller.container.content
                check(!controller.addressField.isEditing && switchedPage != nil
                      && switchedResponder?.isDescendant(of: switchedPage!) == true,
                      "switching tabs while editing the address field focuses the newly selected page")
                controller.selectNextTab(nil)
            }
        }
    }

    // MARK: Switching keeps pages alive

    private func keepAlive() async {
        guard state.tabs.count >= 2 else { return }
        let first = state.tabs[0].id, second = state.tabs[1].id
        state.select(first)
        guard let firstSession = sessions.existingSession(for: first), let secondSession = sessions.existingSession(for: second) else {
            check(false, "both tabs have sessions")
            return
        }
        check(run.showsSelectedTab() && secondSession.view.superview == nil, "selecting the first tab shows its page again")
        check(await run.javaScript(firstSession, "window.arcxMarker = 'kept alive'; return window.arcxMarker") == "kept alive",
              "set a JavaScript variable in the first tab")
        state.select(second)
        check(await run.waitFor { controller.window?.title == "Data fixture" }, "the window title follows the selection to the second tab")
        state.select(first)
        check(sessions.existingSession(for: first) === firstSession, "switching back reuses the same session")
        check(await run.javaScript(firstSession, "return String(window.arcxMarker)") == "kept alive",
              "the JavaScript variable survives a switch away and back, so the page was kept, not reloaded")
        check(await run.waitFor { controller.window?.title == "Fixture B" }, "the window title follows the selection back")
        check(state.tabs[0].title == firstSession.title && state.tabs[1].title == secondSession.title,
              "each tab's title in BrowserState matches its page")
    }

    // MARK: The window, drawn

    private func windowPicture() async {
        if let window = controller.window {
            try? ViewTree.dump(window).write(to: run.output.appendingPathComponent("04-window-tabs-views.txt"), atomically: true, encoding: .utf8)
        }
        let problems = run.sidebarProblems()
        check(problems.isEmpty, "the sidebar is laid out: address field, one row per tab plus New Tab, "
              + "nothing under the traffic lights" + (problems.isEmpty ? "" : ": " + problems.joined(separator: "; ")))
        guard let picture = await run.windowSnapshot("04-window-tabs") else { return }
        let pixels = picture.pixels
        let sidebarInk = pixels.inkCount(in: picture.sidebar)
        check(picture.sidebar.width > 100 && sidebarInk >= 400,
              "the sidebar's own capture is drawn, not blank: \(sidebarInk) px of text and controls in \(Int(picture.sidebar.width))×\(Int(picture.sidebar.height)) px")
        let pink = pixels.share(of: (0xE6, 0x49, 0x80), in: picture.content)
        check(pink > 0.25, "the window picture shows the selected page beside the sidebar: pink covers \(Int(pink * 100))% of the content pane")
        check(pixels.share(of: (0xE6, 0x49, 0x80), in: picture.sidebar) < 0.01, "the page does not spill into the sidebar")
        run.note("04-window-tabs.png is composed: the window frame and the sidebar's hosting view via cacheDisplay, the page via WebKit's snapshot, each drawn into its own frame")
    }

    // MARK: Links that open tabs

    private func linksOpenTabs() async {
        guard let opener = state.selectedTabID, let session = sessions.existingSession(for: opener) else { return }
        session.load(files.links)
        check(await run.settled(session, at: files.links, title: "Links"), "the links page loads")

        // Clicks are synthesised mouse events sent to the web view, so they are user gestures.
        var count = state.tabs.count
        _ = await run.click("blank", in: session)
        if await run.waitFor(10, { state.tabs.count == count + 1 }), let id = state.selectedTabID, id != opener {
            check(state.index(of: id) == (state.index(of: opener) ?? -2) + 1 && samePage(state.tab(id)?.url, files.pageC),
                  "clicking a target=_blank link opens a new selected tab right after its opener")
            if let opened = sessions.existingSession(for: id) {
                check(await run.settled(opened, at: files.pageC, title: "Fixture C"), "the new tab loads the link")
            } else {
                check(false, "the new tab has a session")
            }
            check(samePage(session.url, files.links), "the opener stays on its page")
        } else {
            check(false, "clicking a target=_blank link opens a new selected tab (tabs: \(state.tabs.count))")
        }

        state.select(opener)
        count = state.tabs.count
        _ = await run.click("open", in: session)
        if await run.waitFor(10, { state.tabs.count == count + 1 }), let id = state.selectedTabID, id != opener,
           let opened = sessions.existingSession(for: id) {
            check(await run.settled(opened, at: files.pageA, title: "Fixture A"), "window.open from a click opens a new selected tab on its URL")
        } else {
            check(false, "window.open from a click opens a new selected tab (tabs: \(state.tabs.count))")
        }

        await popupsWithoutGesture()

        // ⌘-click: an AppKit mouse-down/up pair with ⌘ held, sent straight to the web view at the
        // link's position (the window server is bypassed because test windows ignore the mouse).
        state.select(opener)
        count = state.tabs.count
        let created = sessions.createdCount
        let clicked = await run.click("plain", in: session, modifiers: .command)
        if await run.waitFor(10, { state.tabs.count == count + 1 }),
           let id = state.tabs.first(where: { samePage($0.url, files.pageB) && sessions.existingSession(for: $0.id) == nil })?.id {
            check(state.selectedTabID == opener && state.index(of: id) == (state.index(of: opener) ?? -2) + 1,
                  "a ⌘-click (synthesised NSEvent sent to the web view) opens the link in a background tab after its opener")
            check(sessions.createdCount == created && sessions.existingSession(for: id) == nil,
                  "the background tab has no web view until it is selected")
            try? await Task.sleep(for: .milliseconds(300))
            check(samePage(session.url, files.links), "the ⌘-clicked link did not navigate the opener")
        } else {
            check(false, "a ⌘-click (synthesised NSEvent, link found: \(clicked)) opens a background tab (tabs: \(state.tabs.count), opener at \(session.url?.lastPathComponent ?? "nil"))")
        }
        run.note("⌘-click through the window server (a physical mouse) is not verified: test windows ignore the mouse")
    }

    /// A page may not open tabs on its own: `window.open` and a `target=_blank` click from its load
    /// script, and `window.open` from a timer, are all blocked. Then, for the record, whether a
    /// `window.open` run by the app through `callAsyncJavaScript` counts as a user gesture.
    private func popupsWithoutGesture() async {
        guard let id = state.selectedTabID, let session = sessions.existingSession(for: id) else { return }
        let count = state.tabs.count
        session.load(files.popups)
        check(await run.settled(session, at: files.popups, title: "Pop-ups"), "a page that tries to open pop-ups on load loads")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await run.javaScript(session, "return window.popupsDone ? 'done' : ''") == "done" { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let results = await run.javaScript(session, "return window.popupsDone ? window.popupResults.join(',') : 'not done'")
        check(state.tabs.count == count && state.selectedTabID == id,
              "window.open and a target=_blank click from a page's load script, and window.open from a timer, open no tab (tabs \(count) → \(state.tabs.count))")
        check(results == "blocked,blocked", "the page sees both window.open calls return null: \(results ?? "nil")")

        _ = await run.javaScript(session, "window.open('a.html'); return 'called'")
        let opened = await run.waitFor(3) { state.tabs.count == count + 1 }
        run.note("window.open run by the app through callAsyncJavaScript \(opened ? "opens a tab: WebKit treats it as a user gesture" : "is blocked like a page script")")
        if opened, let extra = state.selectedTabID, extra != id { state.closeTab(extra) }
        state.select(id)
        session.load(files.links)
        _ = await run.settled(session, at: files.links, title: "Links")
    }

    // MARK: Order and selection

    private func reorderAndSelect() async {
        let order = state.tabs.map(\.id)
        guard order.count >= 4 else { check(false, "enough tabs to reorder (\(order.count))"); return }
        final class Counter { var changes = 0 }
        let counter = Counter()
        state.observeChanges { _ in counter.changes += 1 }

        state.moveTab(order.last!, to: 0)
        check(state.tabs.map(\.id) == [order.last!] + order.dropLast(), "moving the last tab to the top reorders the list")
        state.moveTabs(fromOffsets: IndexSet(integer: 0), toOffset: order.count)
        check(state.tabs.map(\.id) == order, "a SwiftUI-style move puts it back at the end")
        let changes = counter.changes
        state.moveTab(order[1], to: 1)
        check(counter.changes == changes, "moving a tab to its own place is not a change")
        check(await run.sessionFileMatchesState(), "the saved session follows the new order")

        let item = NSMenuItem()
        item.action = #selector(BrowserWindowController.selectTabByNumber(_:))
        item.tag = 1
        controller.selectTabByNumber(item)
        check(state.selectedTabID == order[0] && run.showsSelectedTab(), "⌘1 selects the first tab")
        item.tag = 9
        controller.selectTabByNumber(item)
        check(state.selectedTabID == order.last && run.showsSelectedTab(), "⌘9 selects the last tab")
        item.tag = 8
        check(!controller.validateMenuItem(item), "⌘8 is disabled with \(order.count) tabs")
        controller.selectTabByNumber(item)
        check(state.selectedTabID == order.last, "⌘8 with \(order.count) tabs changes nothing")
        controller.selectNextTab(nil)
        check(state.selectedTabID == order[0], "Select Next Tab wraps from the last tab to the first")
        controller.selectPreviousTab(nil)
        check(state.selectedTabID == order.last, "Select Previous Tab wraps from the first tab to the last")
        controller.selectPreviousTab(nil)
        check(state.selectedTabID == order[order.count - 2], "Select Previous Tab moves up the list")

        // The background tab from the ⌘-click gets its web view only now, when it is first shown.
        if let background = state.tabs.first(where: { sessions.existingSession(for: $0.id) == nil }) {
            let created = sessions.createdCount
            state.select(background.id)
            if let session = sessions.existingSession(for: background.id) {
                check(sessions.createdCount == created + 1 && run.showsSelectedTab(), "selecting a background tab creates its page")
                check(await run.settled(session, at: background.url, title: "Fixture B"), "and loads the tab's URL then")
            } else {
                check(false, "selecting a background tab creates its page")
            }
        }
    }

    // MARK: Closing and reopening

    private func closeAndReopen() async {
        guard state.tabs.count >= 4 else { check(false, "enough tabs to close (\(state.tabs.count))"); return }
        var ids = state.tabs.map(\.id)
        state.select(ids[1])
        controller.closeTab(nil)
        check(state.tabs.map(\.id) == [ids[0]] + ids[2...] && state.selectedTabID == ids[2],
              "closing the selected tab selects the one below it")
        check(sessions.existingSession(for: ids[1]) == nil && run.showsSelectedTab(), "the closed tab's page is released")

        ids = state.tabs.map(\.id)
        state.select(ids.last!)
        controller.closeTab(nil)
        check(state.selectedTabID == ids[ids.count - 2], "closing the selected last tab selects the one above it")

        ids = state.tabs.map(\.id)
        let selected = state.selectedTabID
        let closedURL = state.tabs[0].url
        state.closeTab(ids[0])
        check(state.selectedTabID == selected && state.tabs.map(\.id) == Array(ids.dropFirst()),
              "closing an unselected tab keeps the selection")

        check(controller.validateMenuItem(menuItem(#selector(BrowserWindowController.reopenClosedTab(_:)))),
              "Reopen Closed Tab is enabled after closing tabs")
        controller.reopenClosedTab(nil)
        check(state.tabs.first?.id == ids[0] && state.selectedTabID == ids[0], "Reopen Closed Tab puts the tab back at its position, selected")
        if let session = sessions.existingSession(for: ids[0]) {
            check(await run.waitFor { !session.isLoading && samePage(session.url, closedURL) },
                  "the reopened tab loads its URL again")
        } else {
            check(false, "the reopened tab has a page")
        }
    }

    // MARK: Collapsed sidebar

    private func collapsedSidebar() async {
        let titlebar = controller.titlebarHeight
        let widthBefore = controller.sidebarWidth
        check(titlebar >= 20, "the title bar area is measured: \(titlebar) pt")
        controller.splitViewController.toggleSidebar(nil)
        // Collapsing animates; wait until the content pane has reached the window's left edge.
        let collapsed = await run.waitFor(5) {
            controller.sidebarItem.isCollapsed && controller.container.topInset == titlebar
                && controller.container.convert(controller.container.bounds, to: nil).minX < 0.5
        }
        check(collapsed, "Toggle Sidebar collapses it and moves the page below the traffic lights (inset \(controller.container.topInset))")
        if collapsed, let page = controller.container.content {
            controller.container.layoutSubtreeIfNeeded()
            let gap = controller.container.bounds.height - page.frame.maxY
            check(abs(gap - titlebar) < 0.5, "the page's top edge sits \(gap) pt below the window top, clear of the traffic lights")
            _ = await run.windowSnapshot("05-window-sidebar-collapsed")
            if run.needsFocus("⌘L expands a collapsed sidebar and focuses the address field") {
                controller.openLocation(nil)
                check(!controller.sidebarItem.isCollapsed && controller.addressField.isEditing
                      && abs(controller.sidebarWidth - widthBefore) < 0.5,
                      "⌘L expands a collapsed sidebar at its width (\(controller.sidebarWidth) pt) and focuses the address field")
                controller.splitViewController.toggleSidebar(nil)
                _ = await run.waitFor(5) {
                    controller.sidebarItem.isCollapsed
                        && controller.container.convert(controller.container.bounds, to: nil).minX < 0.5
                }
            }
        }
        controller.splitViewController.toggleSidebar(nil)
        check(await run.waitFor(5) {
            !controller.sidebarItem.isCollapsed && controller.container.topInset == 0
                && abs(controller.container.convert(controller.container.bounds, to: nil).minX - controller.sidebarWidth) < 0.5
        },
              "Toggle Sidebar again shows it and the page returns to the top")
        check(await run.waitFor(5) { abs(controller.sidebarWidth - widthBefore) < 0.5 },
              "the sidebar comes back at its width (\(controller.sidebarWidth) pt, was \(widthBefore) pt)")
    }

    // MARK: Zero tabs

    private func emptyState() async {
        while state.selectedTabID != nil { controller.closeTab(nil) }
        check(state.tabs.isEmpty && state.selectedTabID == nil, "closing every tab leaves zero tabs; none is created")
        check(controller.container.isShowingEmptyState && controller.container.content == nil, "the content pane shows the empty state")
        check(sessions.liveTabIDs.isEmpty, "every page was released")
        check(await run.waitFor { controller.window?.title == "ArcX" }, "the window title falls back to ArcX")
        check(controller.window?.isVisible == true, "the window stays open with no tabs")
        if let picture = await run.windowSnapshot("06-window-empty") {
            let ink = picture.pixels.inkCount(in: picture.content)
            check(ink >= 300, "the empty state is drawn: \(ink) px of text and symbol in the content pane")
        }
        check(await run.sessionFileMatchesState() && run.savedSnapshot()?.tabs.isEmpty == true, "zero tabs is saved as zero tabs")

        controller.reopenClosedTab(nil)
        check(state.tabs.count == 1 && state.selectedTabID != nil && run.showsSelectedTab(), "Reopen Closed Tab works from zero tabs")
        controller.closeTab(nil)

        check(controller.submitAddress("file://\(files.pageA.path)"), "the address field accepts a URL with no tabs open")
        if state.tabs.count == 1, let id = state.selectedTabID, let session = sessions.existingSession(for: id) {
            check(await run.settled(session, at: files.pageA, title: "Fixture A") && run.showsSelectedTab(),
                  "with no tabs, submitting an address opens it in a new selected tab")
        } else {
            check(false, "with no tabs, submitting an address opens a new selected tab (tabs: \(state.tabs.count))")
        }
    }

    // MARK: Hand-over to the restore phase

    /// Leaves three titled tabs with the middle one selected, flushes through the app's termination
    /// path and records what was saved.
    private func leaveSessionForRestore() async {
        // Dragging the divider (the same call the split view makes): the new width is remembered
        // exactly, and the restore phase must open at it.
        controller.splitViewController.splitView.setPosition(300, ofDividerAt: 0)
        check(await run.waitFor(5) {
            abs(controller.sidebarWidth - 300) < 0.5 && AppDefaults.store.double(forKey: BrowserWindowController.sidebarWidthKey) == 300
        }, "resizing the sidebar to 300 pt remembers 300, got \(controller.sidebarWidth) pt, stored \(AppDefaults.store.double(forKey: BrowserWindowController.sidebarWidthKey))")

        guard let a = state.selectedTabID else { return }
        let b = state.addTab(url: files.pageB, selected: false, after: a)
        let c = state.addTab(url: files.pageC, selected: true, after: b)
        if let session = sessions.existingSession(for: c) {
            _ = await run.settled(session, at: files.pageC, title: "Fixture C")
        }
        state.select(b)
        if let session = sessions.existingSession(for: b) {
            _ = await run.settled(session, at: files.pageB, title: "Fixture B")
        }
        check(await run.waitFor { state.tabs.map(\.title) == ["Fixture A", "Fixture B", "Fixture C"] },
              "three titled tabs are open for the restore phase: \(state.tabs.map(\.title))")
        run.context.terminate()
        check(!run.context.saver.hasPendingSave && run.savedSnapshot() == state.snapshot,
              "the termination path flushes the session, and the file matches the state")
        do {
            try FileManager.default.copyItem(at: run.context.store.fileURL, to: run.expectedSessionFile)
        } catch {
            check(false, "record the expected session: \(error.localizedDescription)")
        }
    }

    private func menuItem(_ action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        item.action = action
        return item
    }
}
#endif
