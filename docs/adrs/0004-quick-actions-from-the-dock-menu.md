# 4. The taskbar shows an app's quick actions, read from its Dock menu

- **Status:** accepted
- **Date:** 2026-11-19
- **Deciders:** Denis Bourge

## Context and problem statement

Right-clicking an app in the Dock gives its quick actions: "New Window" and "New Private
Window" in a browser, its profiles, a mail app's "New Message". Pavé's taskbar replaces the
Dock, and often hides it, so these actions were out of reach.

An app gives these entries to the Dock alone (`applicationDockMenu(_:)`): no public API lets
another process ask for them, and no private one is known. The Dock, however, exposes its items
through Accessibility, as Pavé already reads for the badges (`DockBadges`): asking an item for
its menu (`AXShowMenu`) opens it, and its entries can then be read and pressed.

The Dock gets that menu from the app over a private Mach call (`CopyAppMenu`, in
`HIServices`), on a port the app gives the Dock alone when it registers: there is no way to ask
the app directly, only through the Dock, and the Dock shows the menu when it opens it.

How does the taskbar get an app's quick actions without the Dock's menu flashing on screen?

## Decision

1. **On a right-click on a running app's entry**, Pavé asks the Dock to open that app's menu,
   reads it, closes it, then shows its own menu with the app's quick actions first. Choosing
   one opens the Dock's menu again and presses that entry, found by its titles.
2. **Only the app's own sections are kept**, by their place in the Dock's layout, never by
   their text, which is localized: the window list (first section, recognized by its checked
   entry or a known window title), then "Options ▸" and the last section (Show All Windows,
   Hide, Quit) are dropped. A layout without "Options ▸" before the last section gives no
   quick action at all. The rule is `DockMenu.quickActions` in `PaveCore`, with its tests.
3. **The Dock's menu is hidden while it is open**: just before, Pavé captures the band of
   screen it opens in (700 pt along the Dock's edge, `DockMenu.maskedBand`) and shows that
   still image above it, one window level over the pop-up menus the Dock's menu uses. The
   image stays in memory only, for those few tens of milliseconds. Without the Screen
   Recording permission, or if the capture fails, the menu is read uncovered.
4. **The Accessibility calls run on their own queue**, with a 0.5 s messaging timeout, and give
   the Dock 0.3 s to fill its menu (it takes about 40 ms). Without an answer, the menu shows
   without quick actions. Entries may hold window titles: only counts are logged.

## Options considered

### Read the Dock's menu on every right-click, under a still image — chosen

The quick actions are always those of the moment (a browser's profiles, a new window list),
the menu reads as one list, and nothing flashes. Pavé already has the Screen Recording
permission for the switcher's previews.

### Read it uncovered — rejected

The same without the capture, but the Dock's menu flashes at the edge of the screen on every
right-click and every action: measured, visible.

### A "Quick Actions ▸" submenu, read on demand — rejected

No flash for a plain right-click, but one more step for every action, and the submenu would
still have to wait for the Dock while it is open.

### Ask the app for its menu — impossible

The Dock calls the app over a Mach port only it holds; nothing public or known reaches it.

### An entry that opens the Dock's own menu — rejected

No reading at all, but the menu opens at the Dock's place, far from the pointer, while the
Dock itself may be hidden.

### Static actions from the app's bundle — rejected

macOS apps do not declare their Dock actions in their `Info.plist` (iOS's shortcut items have no
equivalent): almost every action comes from code.

## Consequences

1. **The band along the Dock's edge freezes** for about 50 ms on each right-click, and again
   when a quick action is chosen: a video playing there stops for that long.
2. **The menu shows a little later**: about 150 ms (capture ~40 ms, the Dock ~40 ms, a frame
   on each side), more when ScreenCaptureKit is slow.
3. **Without Screen Recording**, the Dock's menu flashes as it is read.
4. **Only running apps** get quick actions: a pinned app that is not running shows "Open".
5. **A change of the Dock's layout** in a later macOS hides the quick actions rather than
   showing the Dock's own entries; the rule's guard is where to look.
