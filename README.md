# ArcX

A minimal, native browser for macOS with vertical tabs, in the style of Arc.

- **Just the core loop.** Vertical tabs, a ⌘T command bar, tab groups, and a small pop-up window for links from other apps.
- **Native and light.** A Swift shell (AppKit + SwiftUI) around the system's WebKit engine. No bundled browser engine, no web-rendered interface.
- **Tabs that cost nothing when idle.** Background tabs are restored lazily and put to sleep, so memory tracks what you are looking at, not what you have open.

## Requirements

macOS 26 or later on Apple Silicon, Xcode 26, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Build and run

```bash
./Scripts/verify.sh
```

```bash
open .build/xcode/Build/Products/Debug/ArcX.app
```

The first launch opens one tab on a built-in start page. After that the window reopens the tabs you had, with the same one selected; only that tab loads, and the others load when you first select them. Tabs live in a sidebar on the left: ⌘T opens a new tab, ⌘L focuses the address field, ⌘W closes the tab, ⇧⌘T reopens it, ⌃Tab and ⌘1…⌘9 switch tabs, and ⌘S hides or shows the sidebar.

`ARCX_START_URL` opens one more tab, selected, on top of whatever is restored. It is read like text typed into the address field, so a URL, a bare domain or a search all work:

```bash
ARCX_START_URL=localhost:3000 .build/xcode/Build/Products/Debug/ArcX.app/Contents/MacOS/ArcX
```

The session is saved to `~/Library/Application Support/ArcX/session.json`, shortly after each change and when the app quits. Set `ARCX_DATA_DIR` to keep it somewhere else, for example a scratch folder while developing. A session file the app cannot read is renamed to `session.corrupt-<time>.json` and the app starts fresh.

`verify.sh` generates the Xcode project, builds everything and runs the tests. To work in Xcode, run `xcodegen generate` and open `ArcX.xcodeproj`.

## Layout

```
App/                        the macOS app: windows, views, and the WebKit layer
  Engine/                   the only place that imports WebKit
  Windows/                  the browser window and the coordinator that keeps tabs and web views in step
  UI/                       the sidebar, address field and page container
  Resources/                the built-in start page
  Debug/                    the in-app self-test (Debug builds only)
Packages/ArcXKit/
  Sources/ArcXCore/         tabs and BrowserState, the session store, URL and search logic
  Tests/                    unit and budget tests
Scripts/                    verify.sh, selftest.sh
docs/architecture.md        how the pieces fit, with a diagram
```

## Testing

| Command | Runs |
|---|---|
| `./Scripts/verify.sh` | Package build, all tests, app build |
| `./Scripts/verify.sh --ui` | The above, plus the in-app smoke test |
| `Scripts/vm-selftest.sh` | `verify.sh` inside the Tart VM, then the in-app smoke test in the foreground there, so checks that need keyboard focus run too |

The in-app tests drive the real app against local fixture pages and render pages and the window to PNG files in `.build/selftest/`, so they need no accessibility or screen-recording permission and never touch the network. They run in the background: no Dock icon, no visible window, never taking focus, and with their own preferences and data folder (`.build/selftest/data`). The app is launched three times on that folder: a first launch, a relaunch that must restore the session lazily, and a launch on a corrupt session file. Each launch writes `result-<phase>.txt`; `result.txt` combines them. Checks that need keyboard focus are listed as `skip`; run `ARCX_FOREGROUND=1 Scripts/selftest.sh` to watch the run and include them.

## Roadmap

| # | Milestone | Done when | Status |
|---|---|---|---|
| M0 | Skeleton | The project builds, the verify gate runs, and a window shows one web view loading a page | Done |
| M1 | Tabs and sidebar | Open, close, switch and reorder tabs in the vertical sidebar; the session restores on relaunch | Done |
| M2 | Command bar and history | ⌘T and ⌘L work with open-tab, history, URL and search suggestions | |
| M3 | Groups and pinned tabs | Create, rename, collapse, and drag tabs into and out of groups; a pinned section | |
| M4 | Little Arc | Links from other apps and ⌘⌥N open a mini window; "Open in ArcX" moves the tab without a reload | |
| M5 | Browser plumbing | Downloads, pop-ups, permission prompts, find in page, context menus, error pages | |
| M6 | Performance | Tab sleeping, built-in content blocking, measured budgets (basic lazy restore landed in M1) | |
| M7 | Extension spike | A password-manager extension loads and autofills, or a written finding of what blocks it | |

Not in v1: spaces, profiles, sync, split view, the Chrome Web Store, signed releases and auto-update.

See [docs/architecture.md](docs/architecture.md) for the design and [CONTRIBUTING.md](CONTRIBUTING.md) for commit and pull request conventions.
