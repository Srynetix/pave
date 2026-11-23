# 7. The zone picker places one window without changing the screen's layout

- **Status:** accepted
- **Date:** 2026-11-23
- **Deciders:** Denis Bourge

## Context and problem statement

In the ⌃⇧Z picker, two digits (a layout, then one of its zones) put the focused window in that
zone, but first made that layout the screen's: written to the config, and every window already
in zones moved to it. Putting one window in the left third of "thirds" rearranged the whole
screen.

More broadly, a screen's windows in zones always followed a new layout, or a new version of the
one it uses, with no way to keep them where they were.

## Decision

1. **Two digits place the focused window only**: it takes the size and place of that zone; the
   screen keeps its layout and the other windows do not move. ↩ after the first digit, or a
   layout chosen alone, still makes it the screen's layout.
2. **Its zone home follows the screen's layout**: a window placed with another layout is
   remembered in the screen's zones its frame matches, if any, so a re-plug brings it back
   only to zones the screen really has. The rule is `ScreenZones.home` in `PaveCore`, with its
   test.
3. **`[zones] follow`** (default `true`, as before) says whether windows in zones follow a
   screen's new layout or a new version of it; `false`: only the zones change, and each
   window's zone home becomes the zones its frame matches in the new layout, so a re-plug never
   moves it to a zone of the old one. Settings › Zones has its toggle.

## Options considered

### Two digits place only — chosen

The picker then does two distinct things with two distinct gestures: a layout for the screen,
or a zone for one window.

### Keep the old behaviour, ⇧ on the second digit to place only — rejected

No change for those used to it, but the gesture that leaves the other windows alone would be
the hidden one.

### No setting, only the picker's change — rejected

Changing a screen's layout from Settings, the CLI or the editor would still move every window
in zones, with no way to avoid it.

## Consequences

1. **The config format gains a key**: an older Pavé warns about `follow` and ignores it.
2. **A window placed with another layout** is not in the screen's zones for ⌃← / ⌃→, which
   step through the screen's own layout.
