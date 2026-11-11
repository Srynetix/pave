# 1. Pavé follows the P suite's conventions

- **Status:** accepted
- **Date:** 2026-11-11
- **Deciders:** Denis Bourge

## Context and problem statement

Pavé is one of the apps of the [P suite](https://github.com/Srynetix/p-suite), with Prism and
Pastille: apps built almost entirely by AI coding agents, which share the way they are made
rather than their code. The suite wrote its conventions down in `SUITE.md` and checks an app
against them with `just audit`. Pavé already signed its releases and kept its gate local, but
departed on the rest: no contract for agents, no formatter, recipes named its own way, MIT
alone, no SPDX lines, no record of its decisions, a README shaped its own way, and commit
subjects that were not checked although the release notes are made of them.

Which of the suite's conventions does Pavé take, and what does each cost here?

## Decision

All of them.

1. **`AGENTS.md`** is the contract an agent works under, committed; `CLAUDE.md` imports it.
2. **swift-format** formats the sources, configured in `.swift-format` to keep Pavé's style:
   four spaces, 120 columns, existing line breaks respected. Two rules are adjusted rather than
   followed: `ReplaceForEachWithForLoop` is off, and the names `AlwaysUseLowerCamelCase` would
   rename — GitHub's JSON keys, SkyLight's private symbols bound by `@_silgen_name` — are
   marked to be left alone. The whole tree was reformatted once, in a commit of its own.
3. **The suite's recipes**: `doctor`, `install` (the package's dependencies), `dev`, `fmt`,
   `check`, `test`, `ci`, `build`, `changelog`, `release`. `just run` becomes `just dev`, kept
   a while as a private alias; `just install`, which installed the app in `~/Applications`,
   becomes `just deploy`, as in Prism.
4. **`just ci` is the gate**: the commits, the formatting, a build with warnings as errors, the
   string catalog, the SPDX lines, then the tests. `scripts/release.sh` runs it, and checks the
   commits even with `--skip-checks`.
5. **Commits follow Conventional Commits**, checked by `scripts/check-commits.sh`, and the
   release notes are `scripts/changelog.sh`'s: Features, Fixes and Performance since the
   previous `pave-v*` tag, instead of every subject listed as it was.
6. **MIT OR Apache-2.0**, as the suite decided
   ([its ADR 0001](https://github.com/Srynetix/p-suite/blob/main/docs/adrs/0001-dual-licence.md)),
   with the SPDX line in every source file, checked by `scripts/check-spdx.sh`.
7. **The README follows the suite's shape**: the features under *What's inside*, keeping their
   own titles; *Getting started* with *Download the app* and *Build it*; *Privacy*; the suite's
   *How it was made*; *Contributing*. Screenshots move to `docs/screenshots/`.

## Options considered

### Take the suite's conventions — chosen

An agent that has worked on Prism or Pastille finds Pavé's commands, gate and release where it
expects them, and the audit stops reporting Pavé. The cost is one large but mechanical
formatting commit, and two renamed recipes to get used to.

### Take them, without a formatter — rejected

`just fmt` and `just check` would have existed without formatting anything, and the style left
to whoever writes the next line. Rejected: with agents writing most of the code, a formatter
is what keeps the style from drifting, at the cost of one reformatting.

### Keep Pavé's ways where they differ — rejected

Each departure would need its own record and stay in every audit, for habits rather than
reasons.

## Consequences

1. **`git blame` passes through the formatting commit.** Add it to a
   `.git-blame-ignore-revs` if it gets in the way.
2. **Releases up to `pave-v0.6.0` stay under MIT**; the next one is the first under both
   licences.
3. **`just install` changes meaning.** It no longer installs the app; `just deploy` does. The
   private `run` alias goes once the habit has.
4. **The release notes change shape** from the next release: grouped by kind, the rest only
   counted.
