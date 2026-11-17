#if DEBUG
import AppKit

/// How the app behaves when a script runs it for a test (`ARCX_SELFTEST=<output dir>`): with its
/// own preferences and web data, and by default out of the user's way.
///
/// Background mode (the default for test runs; `ARCX_FOREGROUND=1` turns it off):
/// - no Dock icon or menu bar, and the app never comes to the front or takes the keyboard;
/// - its windows are transparent, pushed off-screen and ignore the mouse, while AppKit and WebKit
///   still lay out and draw them;
/// - checks that need keyboard focus cannot run, so `SelfTest` skips them and lists them in result.txt;
/// - App Nap is held off so timers and page loads are not throttled while it is out of sight.
///
/// Every test run (background or not) uses the light appearance, so snapshots are comparable.
///
/// A test run is the same app as a normal launch, so it must not restore or save windows. The script
/// passes `-ApplePersistenceIgnoreState YES`, and every test window is non-restorable with no frame
/// autosave name.
@MainActor
enum TestHost {
    private nonisolated static let environment = ProcessInfo.processInfo.environment

    /// True for any scripted test run.
    nonisolated static let isActive = environment["ARCX_SELFTEST"] != nil
    static let isBackground = isActive && environment["ARCX_FOREGROUND"] != "1"
    static let selfTestOutput = environment["ARCX_SELFTEST"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    /// Which part of the self-test this launch runs (`main`, `restore`, `corrupt`); see `Scripts/selftest.sh`.
    static let selfTestPhase = environment["ARCX_SELFTEST_PHASE"] ?? "main"

    /// Test runs read and write preferences here, never in the user's own domain.
    nonisolated static let defaultsSuite = "app.arcx.ArcX.tests"

    private static let offscreen = NSPoint(x: -30_000, y: -30_000)
    /// Class-name prefixes of the system's text-input helper windows, seen in this app's process.
    private static let systemTextInputWindows = ["NSCampo", "TUINSWindow", "SPRoundedWindow"]
    private static var activity: NSObjectProtocol?

    /// How often a background run was made active (and gave focus back).
    private(set) static var focusTakenCount = 0

    static func willFinishLaunching() {
        guard isActive else { return }
        // Each run starts from empty preferences, like a first launch.
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        // Light appearance whatever the user's setting, so snapshots and their pixel checks are the
        // same on every machine. Dark Mode is therefore not covered by a test run.
        NSApp.appearance = NSAppearance(named: .aqua)
        guard isBackground else { return }
        NSApp.setActivationPolicy(.accessory)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "ArcX test run in the background")
    }

    static func didFinishLaunching() {
        guard isActive else { return }
        let center = NotificationCenter.default
        NSApp.windows.forEach(prepare)
        // AppKit's private "will become visible" notice arrives before a window reaches the screen,
        // so system windows never flash. Undocumented, so the end of every event-loop pass is checked as well.
        center.addObserver(forName: Notification.Name("_NSWindowWillBecomeVisible"), object: nil, queue: nil) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window { prepare(window) } }
        }
        center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.windows.forEach(prepare) }
        }
        if isBackground {
            // macOS sometimes lets the app become active anyway. Hand focus straight back, and count
            // it so the run reports it.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    focusTakenCount += 1
                    NSApp.deactivate()
                }
            }
        } else {
            // In the foreground, ask for focus so checks that need it can run. macOS may still say no
            // while the user is busy in another app; those checks then report themselves as skipped.
            NSApp.activate()
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
    }

    /// Nil when this process cannot restore or save a window. A test that fails this can leave the
    /// next normal launch off-screen.
    static func savedWindowProblem() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        let ignoresSavedState = zip(arguments, arguments.dropFirst()).contains {
            $0 == "-ApplePersistenceIgnoreState" && $1 == "YES"
        }
        if !ignoresSavedState {
            return "a test run must be launched with -ApplePersistenceIgnoreState YES"
        }
        if NSApp.windows.contains(where: \.isRestorable) {
            return "a test window is restorable, so its position can be saved for the next launch"
        }
        if NSApp.windows.contains(where: { !$0.frameAutosaveName.isEmpty }) {
            return "a test window autosaves its frame into the user's preferences"
        }
        return nil
    }

    /// Stops a test window saving its frame over the user's, and in background mode hides it.
    /// Safe to call again on the same window: it only changes what is not already set.
    static func prepare(_ window: NSWindow) {
        window.isRestorable = false
        if window.parent == nil, !window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("") }
        guard isBackground else { return }
        if systemTextInputWindows.contains(where: { NSStringFromClass(type(of: window)).hasPrefix($0) }) {
            window.alphaValue = 0
            if window.isVisible { window.orderOut(nil) }
            return
        }
        // Transparent, but still drawn: AppKit lays it out and WebKit paints into it.
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        // The window server keeps a corner of a titled window on screen, which is why the
        // transparency matters too.
        if window.parent == nil, window.frame.origin != offscreen { window.setFrameOrigin(offscreen) }
    }
}
#endif
