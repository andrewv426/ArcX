import AppKit
import ArcXCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?
    private var saver: SessionSaver?

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        TestHost.willFinishLaunching()
        #endif
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SessionStore(fileURL: AppPaths.sessionFile)
        let loaded = store.load()
        if case .unreadable(let reason, let movedTo) = loaded {
            NSLog("ArcX: the saved session could not be used (%@); moved to %@; starting fresh",
                  reason, movedTo?.path ?? "nowhere")
        }
        let startURL = Self.startURL()
        let state = BrowserState.launching(from: loaded, startPage: Self.startPage, startURL: startURL)
        let saver = SessionSaver(state: state, store: store)
        self.saver = saver
        // A first, recovered, or ARCX_START_URL launch writes its session soon, not only after another change.
        if case .restored = loaded, startURL == nil {} else { saver.setNeedsSave() }

        let controller = BrowserWindowController(state: state, startPageURL: Self.startPage)
        windowController = controller
        #if DEBUG
        TestHost.didFinishLaunching()
        if let output = TestHost.selfTestOutput {
            controller.showWindow(nil)
            let context = SelfTestContext(controller: controller, loaded: loaded, store: store, saver: saver,
                                          startPage: Self.startPage) { [weak self] in
                self?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            }
            Task { await SelfTest.run(context, output: output) }
            return
        }
        #endif
        controller.showWindow(nil)
    }

    /// Writes any pending session change before the process ends.
    func applicationWillTerminate(_ notification: Notification) {
        saver?.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The bundled start page, which never touches the network.
    static let startPage = Bundle.main.url(forResource: "start", withExtension: "html")

    /// `ARCX_START_URL` if set, read the way the address bar reads typed text (so a search works
    /// too). It opens as an extra, selected tab on top of the restored session.
    private static func startURL() -> URL? {
        ProcessInfo.processInfo.environment["ARCX_START_URL"].flatMap { URLClassifier.destination(for: $0) }
    }
}

/// The main menu, built in code. Actions have no target, so they go down the responder chain:
/// standard Edit actions work inside web pages, and tab actions reach `BrowserWindowController`.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        let name = ProcessInfo.processInfo.processName
        typealias Controller = BrowserWindowController

        let appMenu = submenu(in: main, title: name)
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, title: "File")
        file.addItem(withTitle: "New Tab", action: #selector(Controller.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Open Location…", action: #selector(Controller.openLocation(_:)), keyEquivalent: "l")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(Controller.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        file.addItem(withTitle: "Reopen Closed Tab", action: #selector(Controller.reopenClosedTab(_:)), keyEquivalent: "T")

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu(in: main, title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        view.addItem(.separator())
        view.addItem(withTitle: "Reload Page", action: #selector(Controller.reloadPage(_:)), keyEquivalent: "r")

        let history = submenu(in: main, title: "History")
        history.addItem(withTitle: "Back", action: #selector(Controller.navigateBack(_:)), keyEquivalent: "[")
        history.addItem(withTitle: "Forward", action: #selector(Controller.navigateForward(_:)), keyEquivalent: "]")

        let window = submenu(in: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: "Select Next Tab", action: #selector(Controller.selectNextTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control]
        window.addItem(withTitle: "Select Previous Tab", action: #selector(Controller.selectPreviousTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control, .shift]
        window.addItem(.separator())
        for number in 1...9 {
            let title = number == 9 ? "Select Last Tab" : "Select Tab \(number)"
            let item = window.addItem(withTitle: title, action: #selector(Controller.selectTabByNumber(_:)), keyEquivalent: "\(number)")
            item.tag = number
        }
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }
}
