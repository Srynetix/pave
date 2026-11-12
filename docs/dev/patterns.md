# Patterns

The patterns Pavé's code relies on. Each section says what problem the pattern solves here,
where it lives, and how to add one more case without breaking it. When a new pattern enters
the code, it gets a section in the same commit.

## A pure core decides, the shell applies

**The problem.** Window management is mostly rules (where a snap goes, which windows a
workspace hides, what ⌘Tab selects), and macOS makes them slow and flaky to test: they need
the Accessibility permission, real apps and real screens.

**Where.** Every type of [`PaveCore`](../../Sources/PaveCore) decides; the controllers of
[`PaveMac`](../../Sources/PaveMac) apply. The pairs:

| Decides (core) | Returns | Applies (shell) |
|---|---|---|
| [`LayoutEngine`](../../Sources/PaveCore/Layout.swift) | `LayoutAction` (`setFrame`, `minimize`, `none(reason:)`) | [`Commander`](../../Sources/PaveMac/Commander.swift), [`DragSnapController`](../../Sources/PaveMac/DragSnapController.swift) |
| [`Workspaces`](../../Sources/PaveCore/Workspaces.swift) | `[Workspaces.Action]` (`setFrame`, `focus`) | [`WorkspaceController`](../../Sources/PaveMac/WorkspaceController.swift) |
| [`TilingTree`](../../Sources/PaveCore/TilingTree.swift) | `[WindowID: Rect]` | [`TilingController`](../../Sources/PaveMac/TilingController.swift) |
| [`SwitcherSession`](../../Sources/PaveCore/Switcher.swift) | `SwitcherSession.Effect` | [`SwitcherController`](../../Sources/PaveMac/SwitcherController.swift) |
| [`TaskbarModel`](../../Sources/PaveCore/Taskbar.swift) | `[TaskbarItem]` | [`TaskbarController`](../../Sources/PaveMac/TaskbarController.swift) |
| [`Updates`](../../Sources/PaveCore/Updates.swift) | the release and the file to install | [`UpdateService`](../../Sources/PaveMac/UpdateService.swift) |

**How it works.** The shell gathers plain values (window snapshots, screens in Accessibility
coordinates, the config), calls the core, and turns what comes back into AX calls. The core
never calls out, keeps no reference to the shell, and holds no clock: a time it needs is
passed in.

**Adding a case.** Put the rule in the core type, as a function of values, returning an
action; test it in `Tests/PaveCoreTests`. Then teach the controller to apply the new action,
if it is a new one. A rule that needs something from macOS gets it as a parameter.

**Avoid.** Deciding in a controller ("if the window is already on the left half…"): it
cannot be tested there. Passing an `AXUIElement` or an `NSScreen` to the core.

## One thread per application

**The problem.** Every Accessibility call is a blocking IPC to the target app. One hung app
(or one stopped with `kill -STOP`) would freeze anything that calls it.

**Where.** [`AppThread`](../../Sources/PaveMac/AppThread.swift) (a thread with its own run
loop), [`AppConnection`](../../Sources/PaveMac/AppConnection.swift) (all AX state of one app,
confined to its thread), [`WindowRegistry`](../../Sources/PaveMac/WindowRegistry.swift) (one
connection per regular app).

**How it works.** `AppConnection`'s methods only enqueue work on its thread. Results go back
as `Event`s through a sink that hops to the main actor. Each AX request has a timeout
(`messagingTimeout`); an app that exceeds it is marked unresponsive and probed until it
answers again. Notifications in bursts (a drag fires dozens of `kAXMoved`) are coalesced into
one snapshot.

**Adding a case.** A new AX operation is a method on `AppConnection` that enqueues on
`thread`, does the AX calls there, and reports through a completion or the sink. The registry
exposes it to the controllers, which never see an `AppConnection`.

**Avoid.** Any AX call on the main thread, including "just reading one attribute". Touching
an `AppConnection`'s stored state from outside its thread.

## Snapshots and changes

**The problem.** Many features react to the same events: a window created, moved, focused,
destroyed. Each polling macOS on its own would cost AX calls and disagree on what it saw.

**Where.** [`WindowStore.apply`](../../Sources/PaveCore/WindowStore.swift) turns an app's new
snapshot into `[WindowChange]`; [`WindowRegistry`](../../Sources/PaveMac/WindowRegistry.swift)
publishes each batch to its observers (`addChangeObserver`).

**How it works.** An app's connection always sends a full snapshot of its windows, never a
delta. The store compares it with what it knew and derives the changes, so a missed
notification is corrected by the next snapshot (and by a refresh every 30 s). Observers: the
`Commander`, `WorkspaceController`, `TilingController`, `SwitcherController`,
`TaskbarController`, `ArrangementController`.

**Adding a case.** A new kind of change is a case of `WindowChange`, derived in
`WindowStore.apply` and tested in `WindowStoreTests`. A new feature that reacts to windows
registers an observer in its initializer and reads `registry.store` for the rest.

**Avoid.** Reading AX state directly in a feature; keeping a private copy of window frames
that can drift from the store.

## State machines for sessions

**The problem.** The switcher and the pickers live from a key press to a release, a choice or
Escape, with modes (held, search) and many keys. Spread over callbacks, such logic breaks
silently.

**Where.** [`SwitcherSession`](../../Sources/PaveCore/Switcher.swift),
[`ZoneDraft`](../../Sources/PaveCore/ZoneEditing.swift) (the zone editor, with undo); the keys
come from [`HotkeyService`](../../Sources/PaveMac/HotkeyService.swift) as `SwitcherKey` and
`PickerKey`.

**How it works.** The session is a value. Each key is a `mutating` call that changes its
state and may return an `Effect` (focus, close, quit, dismiss). The controller shows the
state and performs the effects. Each tap session has an `id`; `endSession(id)` only ends that
one, so a late callback cannot close the next session.

**Adding a case.** A new key: a case of `SwitcherKey`, sent by the tap; a transition in
`SwitcherSession`, with its test in `SwitcherTests`; an `Effect` if it acts on the world.

**Avoid.** Keeping session state in the panel or the controller.

## The config file is the single source of truth

**The problem.** Settings can change from the file, the menu, the Settings window and the
welcome guide. Several sources of truth would disagree, and the user's file would be
overwritten.

**Where.** [`ConfigStore`](../../Sources/PaveMac/ConfigStore.swift) (reads and watches),
[`PaveConfig.parse`](../../Sources/PaveCore/Config.swift) (validates, every key with a default),
[`ConfigEdit`](../../Sources/PaveCore/ConfigEdit.swift) (changes one key as text),
[`SettingsModel`](../../Sources/PaveApp/SettingsModel.swift) (what Settings shows).

**How it works.** The UI never sets state: it edits the file through `ConfigEdit`, which
keeps the user's comments and order. The watcher sees the write, the file is parsed, and a
valid config is applied everywhere through `AppDelegate.apply`. An invalid file never
replaces a valid config.

**Adding a setting.** A field in `PaveConfig` with its default (equal to the current
behaviour), its key in `parse` through `ConfigField`, a line in the commented template, a test
in `ConfigTests`; then its control in Settings, writing through `ConfigEdit`, and its use in
`AppDelegate.apply`.

**Avoid.** Storing a setting in `UserDefaults` or in a controller's own variable.

## Observers by closure

**The problem.** Controllers must tell the app what happened (a workspace switched, a picker
closed) without knowing the app.

**Where.** Callback properties set by `AppDelegate`: `onChange`, `onClose`, `onChoose`,
`onSave`, `onSwitcher`…, and `addChangeObserver` where several listeners are needed.

**How it works.** The composition root ([`main.swift`](../../Sources/PaveApp/main.swift)) wires
them once, capturing `self` weakly. Callbacks run on the main actor unless their type says
otherwise.

**Adding a case.** A property `onSomething: ((Value) -> Void)?` on the controller, called on
the main actor, set in `AppDelegate`. Use `addChangeObserver` style when more than one
listener is expected.

**Avoid.** A controller reaching into `AppDelegate`, or into another controller it was not
given. Strong captures of `self` in a stored callback.

## Non-activating panels

**The problem.** The taskbar, switcher, pickers and previews must show above other windows
without taking the focus: otherwise "previous window" loses its meaning and the user's window
stops receiving keys.

**Where.** Every `NSPanel` of [`PaveMac`](../../Sources/PaveMac): the
[`SwitcherPanel`](../../Sources/PaveMac/SwitcherPanel.swift) (through its
`NonActivatingPanel` subclass), [`TaskbarPanel`](../../Sources/PaveMac/TaskbarPanel.swift),
[`TaskbarPreview`](../../Sources/PaveMac/TaskbarPreview.swift),
[`ZonePicker`](../../Sources/PaveMac/ZonePicker.swift),
[`ArrangementPicker`](../../Sources/PaveMac/ArrangementPicker.swift),
[`SnapPreview`](../../Sources/PaveMac/SnapPreview.swift),
[`ZonesOverlay`](../../Sources/PaveMac/ZonesOverlay.swift). The keys of an open picker or
switcher come from the event tap, not from AppKit.

**How it works.** The panels never become key or main, ignore the mouse when they only show
something, and join every Space. The zone editor and the launcher are the exceptions: they
take the keyboard on purpose, and give it back when closed.

**Adding a case.** Configure the panel as the existing ones do (non-activating style, its
level, `collectionBehavior` with `.canJoinAllSpaces`); route the keys through a tap session
(`PickerKey`) if it needs any.

**Avoid.** `makeKeyAndOrderFront` on a panel that only shows something.

## Persist after every change, recover at launch

**The problem.** A parked window lives off screen. If Pavé is killed (`kill -9`, a crash), it
must not stay lost.

**Where.** [`StateStore`](../../Sources/PaveMac/StateStore.swift) (JSON in
`~/.local/state/pave`, through [`StateFiles`](../../Sources/PaveIPC/StateFiles.swift)),
[`WorkspaceController`](../../Sources/PaveMac/WorkspaceController.swift),
[`RestartMarker`](../../Sources/PaveMac/Restart.swift), [`DockController`](../../Sources/PaveMac/DockController.swift).

**How it works.** The workspace state is saved after every change. At launch, windows parked
by a previous run are restored, or kept parked when the restart marker says the previous run
quit on purpose to come back (`just dev`, an update). On SIGTERM and SIGINT, Pavé brings
parked windows back before quitting (within 3 s). The Dock's settings are saved before Pavé
changes them, and restored the same way; `pave restore-dock` works without Pavé.

**Adding a case.** State that would leave the user stuck if lost is saved when it changes,
restored at launch, and undone on quit.

**Avoid.** Saving on quit only.

## One parser for the CLI and the agent

**The problem.** The CLI must refuse bad arguments with its usage, and the agent must read
the same arguments; two parsers drift.

**Where.** [`Subcommands`](../../Sources/PaveIPC/Subcommands.swift) (`TilingCommand`,
`ZonesCommand`, `ArrangementCommand`, `UpdateCommand`), [`Protocol`](../../Sources/PaveIPC/Protocol.swift).

**How it works.** `pave` parses the arguments to check them, then sends them as they are;
the agent parses the same `args` with the same function. One request per connection: a JSON
line, answered by one JSON document.

**Adding a command.** A case of `IPCRequest.Command`, a parser in `Subcommands` with its
tests in `SubcommandTests`, its handling in [`AppDelegate+IPC`](../../Sources/PaveApp/AppDelegate+IPC.swift)
calling the same code as the menu or the shortcut, and its line in the `usage` of
[`pave`](../../Sources/pave/main.swift).

**Avoid.** Logic in the CLI beyond parsing and printing.
