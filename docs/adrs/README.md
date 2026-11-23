# Decisions

Every technical decision Pavé has recorded, one record each, numbered in the order they were
taken. Each says what was decided, what else was considered and why it lost, and what follows
from it. Read the one behind a part of the code before proposing to change it.

A record is not rewritten when things move on. A later one revises it and says so in its
status. Decisions taken before the first record are described in [`docs/dev/`](../dev/README.md)
and in the code's comments; they get a record when they are revisited.

Decisions that hold for every app of the P suite are recorded in
[p-suite](https://github.com/Srynetix/p-suite/tree/main/docs/adrs); a record here can cite them.

To add one: copy the shape of the latest record to the next number, and add its line below.

## The project

| # | Decided | In force |
|---|---|---|
| [1](0001-in-line-with-the-p-suite.md) | Pavé follows the P suite's conventions: swift-format, the suite's recipes, a checked gate and commits, MIT OR Apache-2.0. | Yes |
| [2](0002-workspace-by-window-title.md) | New windows go to a workspace by glob patterns on their title (`[apps."…".titles]`), set from the taskbar's "Pin to Workspace". | Yes |
| [3](0003-windows-on-every-workspace.md) | A window can be shown on every workspace: one an app keeps on top (Picture in Picture), a title rule `"all"`, or the taskbar's "Show on All Workspaces". | Yes |
| [4](0004-quick-actions-from-the-dock-menu.md) | The taskbar's right-click menu shows an app's quick actions, read from the Dock's own menu through Accessibility, hidden under a still image of the screen while it is open. | Yes |
| [5](0005-zone-layout-order.md) | The order of zone layouts (picker, Settings, CLI) is `[zones] order`, a list of names covering built-in and user layouts; the others follow in the default order. | Yes |
| [6](0006-zone-editor-switches-layouts.md) | The zone editor opens any layout from a menu and keeps a draft per layout until saved or closed; Save replaces the user's own layout, built-in ones and copies are saved under a new name, and the editor never renames. | Yes |
