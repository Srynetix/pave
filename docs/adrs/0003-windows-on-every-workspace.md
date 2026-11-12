# 3. A window can be shown on every workspace

- **Status:** accepted
- **Date:** 2026-11-12
- **Deciders:** Denis Bourge

## Context and problem statement

Pavé's workspaces park the windows of a hidden workspace at a screen's edge. A Picture in
Picture video (Brave, Chrome, Safari, Firefox) is meant to stay in sight while the user works
elsewhere: macOS shows it on every Space, but Pavé parked it with the rest of its workspace.
Other windows have the same need: a player kept on top, a chat or a meter.

Each Picture in Picture is a new window, with a new ID, every time a video is popped out. So
marking one window by hand does not cover it: the next one must be recognised.

How does a window become "shown everywhere", and what does that mean for the workspace model?

## Decision

1. **`Workspaces.everywhere`**, a set of window IDs. Such a window is never parked; it belongs
   to the workspace shown on its screen and follows it on every switch (`switchTo`, `display`),
   so the taskbar, the switcher, the workspace numbers and the focus follow treat it as part of
   the workspace in front without knowing about it. A switch never gives it the focus, and it
   is never tiled.
2. **Three ways in**:
   - **automatic**: a standard window whose app keeps it above the others (window server layer
     from 1 to 19, read with the public `CGWindowListCopyWindowInfo`) when it opens, or when
     Pavé starts and finds it. That covers every browser's Picture in Picture, with no setting;
   - **a title rule `"all"`**: `[apps."…".titles] "Picture*" = "all"`, for a window that is
     not kept on top, from the taskbar's "Pin to Workspace ▸ This Window ▸ All Workspaces" or
     Settings;
   - **the taskbar's "Show on All Workspaces"** on a window's entry, for this window until it
     closes.
3. **Sending it to a workspace** (⌘⇧N, "Move to Workspace") shows it there only: the user
   chose a place for it.
4. **The set is saved with the rest of the state**, an optional field: a planned restart keeps
   it, and older state files still load. A fresh start finds the automatic and rule cases again;
   a window marked by hand is not, as its workspace is not either.

## Options considered

### The window follows its screen's workspace — chosen

Every caller that asks "which workspace is this window on" gets an answer that is true: the
one in front of it. Only the model's switch code needs to know.

### A workspace number meaning "all" (0, or nil) — rejected

`workspace(of:)` is called in a dozen places (taskbar, switcher, tiling, numbers, focus
follow), each of which would have had to learn the special value; one forgotten would park the
window or switch away on a click.

### Native Spaces' "all Spaces" setting — rejected

Pavé does not use native Spaces; the setting changes nothing while every workspace lives on
one Space.

### A rule only, no automatic detection — rejected

Each browser names its Picture in Picture window differently, and by language; a rule per
browser would be needed before the first video. The layer says what the app means.

## Consequences

1. **Any window an app keeps on top is shown everywhere**, including a player set to "always on
   top". That is what such a window asks for; "Move to Workspace" sends it to one.
2. **The layer is read once, when the window opens** (or at start-up). An app that raises a
   window later is not followed; the title rule or the taskbar covers it.
3. **The state file has a new optional field, `everywhere`.** An older Pavé reading a newer file
   ignores it and parks those windows as before.
