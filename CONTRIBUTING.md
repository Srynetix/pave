# Contributing to Pavé

Thanks for looking. Pavé is a personal project used every day by its author:
issues are welcome, and pull requests too, small and focused ones first. A
short issue first saves you work: say what you would like to change and why,
and we can agree on the shape before you write it.

## Reporting a bug

Open an issue with what you did, what you expected and what happened instead,
your macOS version and Pavé's (About Pavé), and the part of your `config.toml`
involved, if any (`[apps."…".titles]` holds parts of window titles: check them first). The log (`~/Library/Logs/Pave/pave.log`) helps too: it never
holds a window title.

A security problem goes through [SECURITY.md](SECURITY.md), not an issue.

## Build and run

You need macOS 15 or later, Xcode in `/Applications/Xcode.app` and
[just](https://just.systems) (`brew install just`).

```sh
just doctor    # what this machine is missing
just cert      # once: a self-signed "Pave Dev" certificate, so the
               # Accessibility permission survives rebuilds
just dev       # build/Pave.app, logs in build/pave.log
just test      # the unit tests (PaveCore, PaveIPC)
just deploy    # ~/Applications/Pave.app, the copy you use every day
```

Grant **Accessibility** to the build on first launch. Your builds are signed
with your own certificate: they do not look for Pavé's releases, they update
with your next `just deploy`.

## Before sending a change

**Run `just ci`, and say in the pull request that it passed.** There is no
hosted pipeline: nothing checks a pull request but this command, which checks
the commits, the formatting, a build without a warning, the string catalog, the
SPDX lines and every test. `just fmt` fixes the formatting.

- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org):
  `feat(snap): …`, `fix: …`, `docs: …`. The release notes are built from them,
  so the subject is written for someone reading what changed. `just
  check-commits` checks them;
  `ln -s ../../scripts/check-commits.sh .git/hooks/commit-msg` checks each one as
  it is made.
- **Interface strings**: `just strings`, then translate the new ones in
  `Resources/Localizable.xcstrings` (English and French); `just check-strings`
  must pass.
- Logic that does not need macOS goes into `PaveCore`, with tests. A fixed bug
  gets a test that fails without the fix, wherever it can be tested.
- Never log a window title, a title pattern (`ConfigStore.setPrivateKey`) or a workspace name.
- Private APIs only in `Sources/PaveMac/Private.swift`.
- Every source file starts with `SPDX-License-Identifier: MIT OR Apache-2.0` in
  its first three lines; `just spdx` checks it.

## Where things are decided

Technical decisions are recorded in [`docs/adrs`](docs/adrs/README.md), with what
was considered and why it lost. A change that goes against a record comes with
a new one. [`docs/dev`](docs/dev/README.md) describes how the code is built: start there.

## Licence

Unless you state otherwise, any contribution you submit for inclusion is
dual-licensed under MIT or Apache 2.0, as the project is, with no additional
terms.
