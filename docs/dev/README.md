# Developing Pavé

How Pavé is built, for a developer who knows Swift and AppKit but not this code. The
[README](../../README.md) says what Pavé does; [the decisions](../adrs/README.md) say why it was
built this way; these documents say how it is built now.

## Where to start

1. [Architecture](architecture.md): the five targets, what each may depend on, the threads,
   and how a shortcut becomes a moved window. Read it first.
2. [Patterns](patterns.md): the patterns the code relies on (a pure core that decides and a
   shell that applies, per-app threads, snapshots and changes, state machines…), and how to
   add a case to each.
3. [Building and releasing](building.md): the development loop, the signing certificate,
   localization, the release.
4. `just doctor`, `just cert` once, then `just dev`. `just` lists every command.

## Vocabulary

| Term | Meaning | In the code |
|---|---|---|
| Window ID | The window server's `CGWindowID`: a window's identity for its whole life | [`WindowID`](../../Sources/PaveCore/Model.swift) |
| Snapshot | Everything Pavé knows of one window (or one app's windows) at one moment | [`WindowSnapshot`, `AppSnapshot`](../../Sources/PaveCore/Model.swift) |
| Change | What differs between two snapshots: created, destroyed, moved, retitled, focused… | [`WindowChange`](../../Sources/PaveCore/Model.swift) |
| Store | Every known window and the most-recently-used order: the source of truth | [`WindowStore`](../../Sources/PaveCore/WindowStore.swift) |
| Registry | The main-actor owner of the store, fed by every app's connection | [`WindowRegistry`](../../Sources/PaveMac/WindowRegistry.swift) |
| Screen | A display's frame and usable area, in Accessibility coordinates (top-left origin) | [`Screen`](../../Sources/PaveCore/Layout.swift), [`Screens`](../../Sources/PaveMac/Screens.swift) |
| Placement | Where a snap puts a window: a half, a quarter, maximized | [`Placement`](../../Sources/PaveCore/Layout.swift) |
| Zone layout | A FancyZones-style split of a screen, in percent of its usable area | [`ZoneLayout`](../../Sources/PaveCore/ZoneLayout.swift) |
| Workspace | One of nine virtual desktops; native Spaces are not used | [`Workspaces`](../../Sources/PaveCore/Workspaces.swift) |
| Parking | How a window of a hidden workspace is kept out of sight: moved to a screen's edge, its frame remembered | [`ParkingSpot`](../../Sources/PaveCore/ParkingSpot.swift) |
| Tiling tree | The i3-style tree of containers that lays out a tiled workspace | [`TilingTree`](../../Sources/PaveCore/TilingTree.swift) |
| Arrangement | A saved set of windows, their workspaces and places ("Code", "Meeting") | [`Arrangement`](../../Sources/PaveCore/Arrangement.swift) |
| App rule | What the config says about one app: ignore it, its workspace, its zone… | [`AppRule`](../../Sources/PaveCore/Config.swift) |
| Tap | The `CGEventTap` that reads shortcuts and mouse drags before any app sees them | [`HotkeyService`](../../Sources/PaveMac/HotkeyService.swift) |
| Session | A switcher or picker open from a key press to its commit or cancel | [`SwitcherSession`](../../Sources/PaveCore/Switcher.swift) |
| Restart marker | A file saying the quitting Pavé will be back at once, so it keeps windows parked | [`RestartMarker`](../../Sources/PaveMac/Restart.swift) |

## The documents

| Document | Covers |
|---|---|
| [Architecture](architecture.md) | Targets, dependency rule, threads, main flows, platform code, departures |
| [Patterns](patterns.md) | The patterns used, where, and how to extend them |
| [Building and releasing](building.md) | Development loop, signing, localization, releases, private APIs |
