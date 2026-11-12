# Pavé, for agents

Pavé is a window manager for macOS, for people coming from Windows or Linux: a window switcher,
snapping, zones, a taskbar, workspaces and tiling, in a native Swift menu bar agent with a CLI.
It is part of the [P suite](https://github.com/Srynetix/p-suite): read its `SUITE.md` once;
this file says only what is particular to Pavé.

## Where things are

- `Sources/PaveCore/` — pure logic (model, layout, workspaces, tiling, config, updates): no
  AppKit, fast to test. Logic that does not need macOS goes here.
- `Sources/PaveIPC/` — the JSON protocol and Unix socket, shared by the agent and the CLI.
- `Sources/PaveMac/` — everything that talks to macOS: Accessibility, event tap, window server.
- `Sources/PaveApp/` — the menu bar agent, Settings and About windows (SwiftUI).
- `Sources/pave/` — the `pave` command-line tool.
- `Tests/` — Swift Testing suites for `PaveCore` and `PaveIPC`.
- `Resources/` — `Info.plist` (the version), `Localizable.xcstrings`, the release keys.
- `docs/dev/` — how the code is built: architecture, patterns, building and releasing. Read
  `architecture.md` before changing the structure.
- `docs/adrs/` — technical decisions, indexed in its `README.md`.
- `scripts/` — bundling, strings, checks and release; called by the justfile.

## Commands

```bash
just doctor   # what this machine is missing (Xcode, swift-format, the "Pave Dev" certificate…)
just dev      # build and sign build/Pave.app, then (re)launch it; logs in build/pave.log
just fmt
just check    # formatting, a build with warnings as errors, the string catalog
just test
just ci       # the gate: run it before saying a change is done
```

Xcode is required: the Command Line Tools lack the SwiftUI and Swift Testing macro plugins.
The justfile points `DEVELOPER_DIR` at Xcode; a bare `swift build` outside it fails on macros.

## Done means

- `just ci` passed. If it could not run, say so and why; never call a change done without it.
- The change comes with its tests in `PaveCore` or `PaveIPC` wherever it can be tested there; a
  fixed bug with a test that fails without the fix.
- A decision taken on the way is recorded in `docs/adrs/`, and added to its index.
- The code follows [SUITE.md § 12](https://github.com/Srynetix/p-suite/blob/main/SUITE.md#12-code):
  a person could take it over by hand.
- The README, `CONTRIBUTING.md` and `docs/dev/` say what is now true: a new module, flow or
  pattern is documented in the same commit.
- The commit follows Conventional Commits (`feat(snap): …`, `fix: …`); its subject is written
  for a user reading the release notes. `just check-commits` checks it.

## Rules

- **Never launch `build/Pave.app/Contents/MacOS/Pave` from a terminal**: macOS would give the
  Accessibility permission to the terminal. Launch through `just dev` or `open`.
- **Only one Pavé runs at a time.** `just dev` stops the installed copy, `just deploy` restarts
  it. Do not run `just deploy` unless asked: it replaces the copy the author uses every day.
- **Never log a window title, a workspace name or an icon.** The log is meant to be shareable.
- **Private APIs live only in `Sources/PaveMac/Private.swift`.**
- **The core decides, PaveMac applies.** A rule goes in `PaveCore`, as a function of values
  returning an action, with its test; `PaveCore` never imports AppKit or PaveMac, and no AX
  call runs on the main thread ([patterns](docs/dev/patterns.md)).
- **Comments say why, never what or when**: no comment that repeats the code, narrates the
  change or speaks to a reviewer; no code commented out; no `TODO` without an issue. An
  explanation longer than a few lines goes in `docs/dev/`.
- **Every interface string is localized**: `just strings` after adding one, then its French
  translation in `Resources/Localizable.xcstrings`; `just check-strings` must pass.
- Signing matters: builds are signed with the "Pave Dev" certificate so the Accessibility
  permission survives rebuilds, and releases must be signed with the same one. Never change
  `Resources/update-key.pub` or `Resources/update-cert.sha256`.
- Fix the cause, not the check: never weaken a test, a lint rule or the gate to make it pass.
- Every source file starts with `SPDX-License-Identifier: MIT OR Apache-2.0` in its first three
  lines (`just spdx`).
- Everything in the repository is written in English: code, comments, docs, commits.

## Ask before

- adding a dependency to `Package.swift`;
- changing the format of `config.toml`, the state files or the IPC protocol: installed copies
  and the CLI depend on them;
- running `just deploy`, `just release`, pushing a tag, or anything that publishes;
- deleting files you did not create.
