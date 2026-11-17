# Contributing

## Before you commit

```bash
./Scripts/verify.sh          # package build, all tests, app build
./Scripts/verify.sh --ui     # also the in-app smoke test (in the background)
```

Warnings are errors in every target.

## Commits

```
type(scope): summary in the imperative, 72 characters at most
```

| Type | Use it for |
|---|---|
| `feat` | A capability a user can now see |
| `bug` | A fix for behaviour that was wrong |
| `perf` | Faster or lighter with the same behaviour; quote the `PERF` line before and after |
| `refactor` | Restructuring with no behaviour change |
| `test` | Tests, fixtures or the verify gate only |
| `docs` | Documentation and templates only |
| `build` | Project config, dependencies, build scripts |
| `chore` | Anything else that does not touch shipped code |

Scopes are optional: `core`, `engine`, `sidebar`, `commandbar`, `little`, `app`.

Keep one logical change per commit, and make each commit build on its own. The repository ships a commit message template; turn it on once per clone:

```bash
git config commit.template .gitmessage
```

## Pull requests

The title follows the commit format. The description is filled in from [the template](.github/pull_request_template.md):

- **What this changes** in plain language a newcomer could follow.
- **Why**, with the issue or milestone if there is one.
- **Changes**: a table of files, line counts and the reason each one changed.
- **Visuals** when relevant: screenshots for UI changes, and the updated part of [docs/architecture.md](docs/architecture.md) when a process, target, store or data flow changes.
- **How it was checked**, including what was not tested.

Screenshots do not need screen-recording permission: `Scripts/selftest.sh` renders the running app to PNG files in `.build/selftest/`.

## Where things go

| Change | Place | Test it in |
|---|---|---|
| Tabs, groups and selection; session and history storage; URL classification; suggestion ranking | `Packages/ArcXKit/Sources/ArcXCore` | `ArcXCoreTests` |
| Anything that touches WebKit: web view setup, tab sleeping, content blocking, downloads, extensions | `App/Engine` | `App/Debug/SelfTest.swift` |
| Windows, sidebar, command bar, Little Arc | `App/` | `App/Debug/SelfTest.swift` |
| A performance budget | `Tests/ArcXPerfTests` or `SelfTest.runPerformance` | `./Scripts/verify.sh --ui` |

Logic belongs in the package, where it runs headless in milliseconds. `App/` holds windows, views and the WebKit layer only, and `import WebKit` appears only under `App/Engine`.
