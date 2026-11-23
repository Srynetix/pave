# 5. The order of zone layouts is a list in `[zones]`

- **Status:** accepted
- **Date:** 2026-11-23
- **Deciders:** Denis Bourge

## Context and problem statement

Zone layouts were always shown in the same order: the built-in ones, then the user's sorted by
name. That order matters in the ⌃⇧Z picker, where 1 to 9 choose a layout by its place. A layout
used every day could end up seventh only because of its name, and nothing could move it.

The user's layouts are `[layouts."<name>"]` tables, read into a dictionary: the file gives no
order Pavé keeps.

Where does Pavé keep the order the user wants, and which layouts does it cover?

## Decision

1. **`[zones] order` is a list of layout names**, built-in or the user's, for example
   `order = ["Coding", "focus"]`. The layouts it names come first, in its order. The others
   follow in the previous order (built-in layouts, then the user's sorted by name), so a config
   without `order` shows what it showed before, and a new layout appears at the end.
2. **A name no layout has is a warning, not an error**: a layout deleted by hand does not stop
   the config from loading. A name written twice counts once.
3. **Settings writes the whole list** when a layout is dragged in the Layouts list, and takes a
   layout out of the list when it deletes that layout. The rule is `ZoneSettings.names` and
   `ZoneSettings.order(moving:to:)` in `PaveCore`, with their tests.
4. **The picker, Settings and `pave zones` all show `names`.**

## Options considered

### A list in `[zones]` covering every layout — chosen

One key, optional, readable, edited by hand as easily as from Settings. Built-in layouts can be
moved too, so a user layout can take key 1.

### The order of the `[layouts."…"]` tables in the file — rejected

Nothing new in the format, but the TOML reader would have to keep the order of tables, built-in
layouts could not be placed, and reordering would mean moving whole tables in the file.

### An `order = N` key in each `[layouts."…"]` table — rejected

Built-in layouts have no table to hold it, and moving one layout means renumbering the others.

## Consequences

1. **The config format gains a key**: an older Pavé reading a config with `order` warns about an
   unknown setting and ignores it.
2. **After the first drag, `order` names every layout**, built-in ones included: a built-in
   layout a later Pavé adds is not in the list, so it comes after all of them, not among the
   built-in ones.
3. **Renaming a layout by hand** without updating `order` moves it back to the default place,
   with a warning.
