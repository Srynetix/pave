# 2. New windows go to a workspace by their title, with glob patterns

- **Status:** accepted
- **Date:** 2026-11-12
- **Deciders:** Denis Bourge

## Context and problem statement

An app rule could already send an app's new windows to a workspace (`workspace = N`), and a
browser's by profile (`[apps."…".profiles]`, the title ending with ` - <profile>`). Two needs
were left: setting the app's workspace from the taskbar, where the app is, rather than in
Settings; and sending windows by title when the app does not separate the profile with
` - `. Prism ends its titles with the profile's name alone; an editor names the project
anywhere in the title.

How should a rule match a title, and where is it written?

## Decision

1. **`[apps."<bundle id>".titles]`**: one key per pattern, its value the workspace.
   `"*Work" = 3`. A pattern matches the whole title, `*` is any text, `?` one character, case
   ignored.
2. **The most specific pattern wins**: the most characters other than `*`, then alphabetical
   order. The parser does not keep the order of a table, and the result must not depend on it.
3. **Profiles first, then titles, then `workspace`.** Titles are looked at again for 2 s after
   the window opens, as profiles already were: apps name their window a moment later.
4. **The taskbar's menu has "Pin to Workspace ▸"**: under "All <App> Windows", 1…9 / Not
   Pinned writes the app's `workspace`; "This Window ▸ 1…9" writes a title rule from the
   window's title (`*<title>`) and opens it in Settings to be shortened, since the full title
   rarely comes back; "Pin by Window Title…" opens the app's rule in Settings. There, a title
   rule can also start from any open window's title, and each shows how many open windows it
   matches. The window's entry says which windows a choice covers: right-clicking a window and
   finding only the app's workspace led to pinning the whole app by mistake.
5. **A pattern is never logged**: it is part of a title. `ConfigStore` writes it with
   `setPrivateKey`, which logs the table only, and a parse error names the line, not the key.

## Options considered

### Glob patterns in a table — chosen

The shape of `profiles`, so `ConfigEdit` can change one pattern as text, and easy to write
without knowing regular expressions. `"* - Work"` does what a profile does, so profiles could
one day become a case of it.

### Regular expressions — rejected

More powerful, but `.` and `(` in titles would need escaping, a typo makes the file invalid,
and nothing asked for more than "ends with" or "contains".

### An ordered list, `[[apps."…".match]]` — rejected

The order would settle conflicts, but the TOML parser does not read arrays of tables, and
`ConfigEdit` would need to change entries of a list as text. The most-specific rule settles
the same conflicts without an order.

### "Ends with" only, like profiles without ` - ` — rejected

Enough for Prism, not for an editor naming the project in the middle of its title.

## Consequences

1. **A title is only matched when the window opens**, and for 2 s after. A window that changes
   title later (a tab, a file) stays where it is: moving it then would pull it from under the
   user.
2. **Deleting an app rule deletes its subtables** (`titles`, `profiles`): `ConfigEdit.removeTable`
   now removes `[table.*]` too.
3. **`ConfigEdit` quotes keys that need it** and reads quoted keys with escapes, so a pattern
   with `=`, `#` or `"` is written and found again.
4. **Pinning does not move the windows already open**: "Move to Workspace" does that.
