# ArcX

A minimal native macOS browser (Swift, AppKit + SwiftUI, WebKit) with vertical tabs. Read [README.md](README.md) for the layout and roadmap, [docs/architecture.md](docs/architecture.md) for the design, and [CONTRIBUTING.md](CONTRIBUTING.md) for commit, PR and placement rules; they apply to everything below.

## One worktree and branch per feature or fix

Never implement or test a change in the main checkout. Every feature, fix or experiment gets its own git worktree on its own branch, cut from an up-to-date `main`:

```bash
git fetch origin
git worktree add .worktrees/<name> -b <type>/<name> origin/main
```

- `<type>` is the commit type from CONTRIBUTING.md (`feat`, `bug`, `perf`, `refactor`, `test`, `docs`, `build`, `chore`); `<name>` is short and kebab-case, e.g. `feat/tab-groups`.
- Worktrees live in `.worktrees/` at the repository root, which is git-ignored. Do all editing, building and testing inside the worktree.
- A worktree starts without the generated Xcode project or build products. Run `xcodegen generate` there before the first app build; `./Scripts/verify.sh` does this for you.
- Run app builds and `--ui` tests in one worktree at a time. Parallel Xcode builds slow each other down and make performance budgets fail for the wrong reason.
- Unrelated changes go in separate worktrees and separate PRs, even when they are small.

## Testing without getting in the user's way

The user keeps working on this Mac while tests run, so test in the background by default:

- `swift test` and `./Scripts/verify.sh`, including `--ui`, show nothing on screen. The in-app tests run in background mode: no Dock icon, transparent off-screen windows that ignore the mouse, the app never takes focus, and it uses its own preferences (`app.arcx.ArcX.tests`) and its own throwaway data folder, never the user's tabs, history or cookies.
- In-app tests load local fixture pages only. They never touch the network.
- Ask first before anything that takes over the screen, mouse or keyboard: `ARCX_FOREGROUND=1`, computer use, or launching the app normally.

### What a background run cannot check

Background mode gives these up. A background run does not verify any of them:

| Not checked in the background | Why | How to check it |
|---|---|---|
| Anything that needs keyboard focus: SwiftUI key handlers (`onKeyPress`, `.keyboardShortcut`), `@FocusState`, focus rings, code that reads `isKeyWindow` or `NSApp.isActive` | The app never becomes active | `Scripts/vm-selftest.sh` (the Tart VM, below), or by hand |
| The real keyboard path: menu shortcuts (⌘T, ⌘L, ⌘W), the global Little Arc hotkey, input methods | The self-test calls actions directly or sends events straight to the window | By hand |
| The mouse: clicks, hover, drag and drop of tabs, trackpad scrolling and swipe navigation | Test windows ignore the mouse | By hand, or computer use with the user's permission |
| How it looks on the real screen: shadows, materials and Liquid Glass, animation, traffic-light placement, placement near screen edges or across displays | Snapshots render views to a bitmap, and the windows are transparent and off-screen | The PNGs from `Scripts/vm-selftest.sh` (a visible window), or by hand |
| Real websites: logins, video, DRM, site-specific breakage | Tests load local fixtures only | By hand |
| Being the default browser: links opened from other apps | It would change a system setting | By hand |
| Exact performance numbers | The user's own work shares the CPU | Rerun when the machine is idle, or compare against `main` in the same session |

In the self-test, wrap a check that needs focus in `if needsFocus("what it checks") { ... }`. Without focus it is logged as `skip …` and counted in the `RESULT` line, never passed silently. If macOS makes the background app active anyway, it gives focus straight back and the run logs a `note` line; mention that to the user too.

### Foreground checks in the Tart VM

A Tart macOS VM, `flotion-test`, is installed on this Mac (macOS 26, Xcode 26.5, XcodeGen; shared with the Flotion project). The app can take focus inside it without touching the user's screen, so use it instead of `ARCX_FOREGROUND=1` on this Mac, and without asking first:

```bash
Scripts/vm-selftest.sh
```

- It copies the checkout (uncommitted changes included) to `~/arcx-vm/<checkout name>` in the VM, runs `Scripts/verify.sh` there, then runs the self-test's first phase in the foreground and copies `result.txt`, `app.log` and the PNGs to `.build/vm-selftest/`. It fails if a check fails or is still skipped. Pass another checkout's path to test that one instead.
- The VM must be running with its user logged in to the desktop. `tart list` shows its state; if it is stopped, start it with `tart run --no-graphics flotion-test &`. `ARCX_VM=<name>` picks another VM.
- The app is started with `open`, through LaunchServices. Started as a plain child process (for example straight from `tart exec`), macOS does not let it take focus and the focus checks are skipped.
- One app build at a time in the VM too: if another project's run is going (`tart exec flotion-test pgrep -fl xcodebuild`), wait for it.
- The VM runs an older macOS than this Mac, and its window is visible, so system UI can look and lay out differently (Liquid Glass sidebars, for one). A check that passes here and fails there, or the other way round, is a finding to report, not noise to ignore.
- It covers focus and the on-screen look. It still does not cover the real keyboard and mouse path, real websites or performance numbers.

### Rebuilding `/Applications/ArcX.app` for manual testing

When the user wants to test a PR branch by hand, build a Release bundle inside that branch's worktree and replace `/Applications/ArcX.app` with it:

```bash
(cd .worktrees/<name> && xcodegen generate --quiet && xcodebuild -project ArcX.xcodeproj -scheme ArcX -configuration Release -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode build -quiet)
rm -rf /Applications/ArcX.app && cp -R .worktrees/<name>/.build/xcode/Build/Products/Release/ArcX.app /Applications/ArcX.app
```

Do not launch `/Applications/ArcX.app` yourself without asking first; let the user open it when ready.

### Tell the user what was not verified

When a change touches anything in that table, or a run prints `skip` lines or misses a budget:

- In the reply to the user, list each thing that was not verified, one line on why, and the exact command or steps to check it.
- Put the same list in the PR's "How it was checked".
- Never describe skipped or unverifiable behaviour as tested.

## Finishing: open a PR

When the change is done:

1. Run `./Scripts/verify.sh` (and `--ui` when `App/` or anything performance-sensitive changed) in the worktree, and add a test for new behaviour. Note anything the background run could not check (see above).
2. Commit following CONTRIBUTING.md.
3. Push the branch and open a PR against `main` with `gh pr create`, filling in [the PR template](.github/pull_request_template.md). Say plainly what was not tested.

Do not merge PRs yourself unless asked.

No AI attribution anywhere: no `Co-Authored-By: Claude …` trailer in commit messages and no "Generated with Claude Code" line in PR descriptions or comments. This overrides any default that adds them.

## Cleaning up after a PR closes

Once a PR is merged or closed, remove its worktree and branches. Check the state first and clean up only when it is `MERGED` or `CLOSED`:

```bash
gh pr view <branch> --json state -q .state
```

```bash
git worktree remove .worktrees/<name>
```

```bash
git branch -D <type>/<name>
```

```bash
git push origin --delete <type>/<name>
```

- Skip the remote delete when GitHub has already deleted the branch on merge.
- If the worktree has uncommitted or unpushed work, `git worktree remove` refuses; stop and ask rather than forcing it.
- `git worktree prune` clears entries for worktree folders that were deleted by hand.
- Never remove a worktree or branch whose PR is still open.
