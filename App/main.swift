import AppKit

// AppKit lifecycle, no storyboard and no SwiftUI `App`, so a test run can configure the
// process (no Dock icon, no activation) before anything reaches the screen.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
