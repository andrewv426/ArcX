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

The window opens a built-in start page. To open somewhere else, set `ARCX_START_URL`; it is read like text typed into the address bar, so a URL, a bare domain or a search all work:

```bash
ARCX_START_URL=localhost:3000 .build/xcode/Build/Products/Debug/ArcX.app/Contents/MacOS/ArcX
```

`verify.sh` generates the Xcode project, builds everything and runs the tests. To work in Xcode, run `xcodegen generate` and open `ArcX.xcodeproj`.

## Layout

```
App/                        the macOS app: windows, views, and the WebKit layer
  Engine/                   the only place that imports WebKit
  Windows/                  window controllers
  UI/                       views
  Resources/                the built-in start page
  Debug/                    the in-app self-test (Debug builds only)
Packages/ArcXKit/
  Sources/ArcXCore/         tabs, groups, session, history, URL and search logic
  Tests/                    unit and budget tests
Scripts/                    verify.sh, selftest.sh
docs/architecture.md        how the pieces fit, with a diagram
```

## Testing

| Command | Runs |
|---|---|
| `./Scripts/verify.sh` | Package build, all tests, app build |
| `./Scripts/verify.sh --ui` | The above, plus the in-app smoke test |

The in-app tests drive the real app against local fixture pages and render the page to PNG files in `.build/selftest/`, so they need no accessibility or screen-recording permission and never touch the network. They run in the background: no Dock icon, no visible window, never taking focus, and with their own preferences and data. Checks that need keyboard focus are listed as `skip`; run `ARCX_FOREGROUND=1 Scripts/selftest.sh` to watch the run and include them.

## Roadmap

| # | Milestone | Done when | Status |
|---|---|---|---|
| M0 | Skeleton | The project builds, the verify gate runs, and a window shows one web view loading a page | In progress |
| M1 | Tabs and sidebar | Open, close, switch and reorder tabs in the vertical sidebar; the session restores on relaunch | |
| M2 | Command bar and history | ⌘T and ⌘L work with open-tab, history, URL and search suggestions | |
| M3 | Groups and pinned tabs | Create, rename, collapse, and drag tabs into and out of groups; a pinned section | |
| M4 | Little Arc | Links from other apps and ⌘⌥N open a mini window; "Open in ArcX" moves the tab without a reload | |
| M5 | Browser plumbing | Downloads, pop-ups, permission prompts, find in page, context menus, error pages | |
| M6 | Performance | Lazy restore, tab sleeping, built-in content blocking, measured budgets | |
| M7 | Extension spike | A password-manager extension loads and autofills, or a written finding of what blocks it | |

Not in v1: spaces, profiles, sync, split view, the Chrome Web Store, signed releases and auto-update.

See [docs/architecture.md](docs/architecture.md) for the design and [CONTRIBUTING.md](CONTRIBUTING.md) for commit and pull request conventions.
