# 6. The zone editor switches layouts and keeps a draft for each

- **Status:** accepted
- **Date:** 2026-11-23
- **Deciders:** Denis Bourge

## Context and problem statement

The zone editor opened on one layout. A "Start from…" menu replaced the zones with a built-in
layout's, and only those; whether Save replaced a layout or made a new one depended on the name
field: empty for a built-in layout, filled for the user's own, and changing that name silently
made a copy and kept the original. The menu was also hard to read: its controls kept the
system's appearance on the editor's dark toolbar.

How does the editor let the user open any layout, and say plainly what Save writes?

## Decision

1. **A Layout menu lists every layout**, in the picker's order, then "New layout" (a single
   zone). Built-in layouts are marked, layouts with unsaved changes carry a dot.
2. **Each layout opened keeps its draft** until it is saved or the editor closes: switching
   never loses changes. Esc or Cancel with unsaved changes first names them, and discards them
   the second time. The rule is `ZoneEditorSession` in `PaveCore`, with its tests.
3. **Save replaces the user's own layout under its name.** A built-in or new layout shows a
   name field and is saved under that name; the user's own layout is copied with "Save as
   copy…". A copy never takes the name of another layout. The editor does not rename.
4. **Saving with other drafts still changed keeps the editor open** and names them; otherwise
   it closes as before. Opened from a screen, only the layout it opened on, or a copy or new
   layout saved from it, is then used on that screen: saving another layout leaves the screen
   alone (`ZoneEditorSession.origin`).
5. **The toolbar is always dark** (`vibrantDark`), whatever the system's appearance.

## Options considered

### A draft per layout — chosen

Going from one layout to another and back, to compare or to borrow a proportion, costs
nothing. The dots and the message on Cancel keep the drafts visible.

### Confirm before switching — rejected

One draft at a time, simpler to hold, but every switch with changes asks first.

### Keep "Start from…" for new layouts — rejected

A new layout from a template's zones was one click. It is now the template opened, then "Save
as copy…" (or its name typed, for a built-in one): the same result, one menu instead of two
that both changed the zones.

### Switch at once, ⌘Z goes back — rejected

No state to keep, but a change made a few switches ago is easy to lose without noticing.

### Rename in the editor — rejected

Useful, but a rename must follow the name through `[zones.screens]`, `[zones.workspaces]` and
`order`: several writes to the config for one click. Renaming stays a matter of the file.

## Consequences

1. **Drafts live only while the editor is open**: closing it discards them, after the warning.
2. **A new layout starts from a single zone**: to start from a template, open it and save a
   copy.
