import AppKit
import PaveCore
import PaveIPC

/// Applies the pure `Workspaces` model to real windows: parks / restores them
/// through the registry, persists the state after every change, recovers
/// parked windows left by a crash, and watches for windows escaping their
/// parking spot (M0 / H4 "bounce").
@MainActor
public final class WorkspaceController {
    public private(set) var state = Workspaces()

    private let registry: WindowRegistry
    private let store: StateStore
    /// Where each parked window really ended (macOS may clamp the requested spot).
    private var parkedAt: [WindowID: Rect] = [:]
    /// Windows Pavé is moving right now: their frame changes are ours.
    private var inFlight: Set<WindowID> = []
    /// Focus events during and right after a transition are side effects of it.
    private var ignoreFocusUntil = Date.distantPast
    public private(set) var bounces = 0
    /// `workspaces.enabled` in the config. Crash recovery and `restore-all`
    /// work either way: windows parked by an earlier run must always come back.
    public private(set) var isEnabled = false

    /// Turning workspaces off brings every parked window back. Turning them on
    /// starts fresh: each screen shows a workspace, each window joins its screen's.
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        Log.info("workspaces \(enabled ? "enabled" : "disabled")")
        if !enabled, state.hiddenCount > 0 { restoreAll(source: "workspaces disabled") }
        if enabled, recoveryDone { regroup(reason: "enabled") }
        onChange()
    }

    public init(registry: WindowRegistry, store: StateStore = StateStore()) {
        self.registry = registry
        self.store = store
        registry.addChangeObserver { [weak self] in self?.handle($0) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screensDidChange() } }
    }

    private var screenObserver: NSObjectProtocol?
    private var screenChangeWork: DispatchWorkItem?
    /// Screen ids of the last `screensChanged` given to the model.
    private var knownScreens: [String] = []

    // MARK: - Start-up recovery

    /// Call before `registry.start()`.
    public func start() {
        let leftover = store.load()
        registry.onReady = { [weak self] in self?.recover(leftover) }
    }

    /// False until windows parked by a previous run are back (or there were none).
    private var recoveryDone = false
    /// Windows the start-up recovery brought back.
    private var recoveredCount = 0
    /// `restore-all` requests that arrived before recovery finished (e.g. the CLI
    /// relaunching Pavé after a crash): they wait, then report what recovery did.
    private var waitingForRecovery: [@MainActor (Int) -> Void] = []

    /// Written by a run that quits to be restarted at once (`just run`,
    /// `just install`): it left its windows parked, the next run resumes.
    public static var resumeMarker: URL { StateFiles.url("resume") }

    /// Quitting for a restart: parked windows stay parked, the state on disk
    /// is current (saved after every change). False: bring them back first.
    public func prepareRestart() -> Bool {
        guard isEnabled, recoveryDone else { return false }
        persist()
        try? StateFiles.touch(Self.resumeMarker)
        Log.info("restart: \(state.hiddenCount) parked window(s) left parked for the next run")
        return true
    }

    private func recover(_ leftover: Workspaces?) {
        let marker = Self.resumeMarker
        let markedAt = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date
        try? FileManager.default.removeItem(at: marker)
        // A fresh marker only: an old one means the restart never happened.
        if let markedAt, Date().timeIntervalSince(markedAt) < 120, isEnabled, var resumed = leftover {
            let screens = Screens.all()
            let windows = registry.store.orderedWindows
            let before = resumed.hiddenCount
            // Every window the window server still knows (IDs only, never titles).
            let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let alive = Set(info.compactMap { ($0[kCGWindowNumber as String] as? UInt32).map { WindowID($0) } })
                .union(windows.map(\.id))
            let actions = resumed.resume(screens: screens, windows: windows, alive: alive)
            state = resumed
            knownScreens = screens.map(\.id)
            persist()
            Log.info("workspaces (restart): resumed, \(state.hiddenCount) parked (\(before) left by the previous run), \(describeVisible(screens))")
            recoveryDone = true
            if !actions.isEmpty { execute(actions, label: "resume") { _ in } }
            let waiting = waitingForRecovery
            waitingForRecovery = []
            for completion in waiting { restoreAll(source: "cli (after recovery)", completion: completion) }
            return
        }
        guard var leftover, leftover.hiddenCount > 0 else {
            finishRecovery()
            return persist()
        }
        let parked = leftover.savedFrames.count
        let known = leftover.savedFrames.keys.filter { registry.store.windows[$0] != nil }.count
        Log.info("recovery: \(parked) window(s) parked by a previous run, \(known) still exist")
        let actions = leftover.restoreAll(screens: Screens.all())
        execute(actions, label: "recovery") { [weak self] shown in
            self?.recoveredCount = shown
            self?.persist()
            self?.finishRecovery()
        }
    }

    private func finishRecovery() {
        recoveryDone = true
        if isEnabled { regroup(reason: "start") }
        let waiting = waitingForRecovery
        waitingForRecovery = []
        for completion in waiting { restoreAll(source: "cli (after recovery)", completion: completion) }
    }

    // MARK: - Commands

    public func switchTo(_ target: Int, source: String, completion: @escaping @MainActor (String) -> Void = { _ in }) {
        guard isEnabled else { return completion("workspaces are disabled (workspaces.enabled in the config)") }
        // Locked session: macOS refuses to move windows, the model would lie.
        guard !registry.isSessionLocked else { return completion("session locked, ignored") }
        let screens = Screens.all()
        guard let focused = focusedScreen(among: screens) else { return completion("no screen") }
        let from = state.active
        let wasVisible = state.isVisible(target)
        let actions = state.switchTo(target, focusedScreen: focused, screens: screens, windows: registry.store.orderedWindows)
        guard state.active != from || !wasVisible && state.isVisible(target) else {
            Log.info("\(source) workspace \(target): no-op (already active or invalid)")
            return completion("workspace \(state.active) already active")
        }
        ignoreFocusUntil = .distantFuture
        persist()
        let screen = state.screen(showing: target).flatMap { id in screens.firstIndex { $0.id == id } }.map { "screen\($0)" } ?? "?"
        execute(actions, label: "\(source) workspace \(from) → \(target) (\(wasVisible ? "focus only" : "shown"), \(screen))") { [weak self] _ in
            self?.ignoreFocusUntil = Date().addingTimeInterval(0.4)
            completion("workspace \(target)")
        }
    }

    /// `pave workspace N --screen S`. `selector`: the screen's index (0 is
    /// the primary one, as in the logs), part of its name ("LG"), "builtin",
    /// or its UUID.
    public func display(_ target: Int, onScreen selector: String, source: String, completion: @escaping @MainActor (String) -> Void) {
        guard isEnabled else { return completion("workspaces are disabled (workspaces.enabled in the config)") }
        guard !registry.isSessionLocked else { return completion("session locked, ignored") }
        let screens = Screens.all()
        guard let index = Screens.index(matching: selector), index < screens.count else {
            return completion("no screen matches \"\(selector)\" (\(Screens.names().enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: ", ")))")
        }
        let screen = screens[index]
        let from = state.active
        let actions = state.display(target, on: screen, screens: screens, windows: registry.store.orderedWindows)
        guard state.screen(showing: target) == screen.id else { return completion("invalid workspace \(target)") }
        ignoreFocusUntil = .distantFuture
        knownScreens = screens.map(\.id)
        persist()
        execute(actions, label: "\(source) workspace \(from) → \(target) (on screen\(index))") { [weak self] _ in
            self?.ignoreFocusUntil = Date().addingTimeInterval(0.4)
            completion("workspace \(target) on screen \(index)")
        }
    }

    public func move(
        _ windowID: WindowID?, to target: Int, source: String,
        completion: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        guard isEnabled else { return completion("workspaces are disabled (workspaces.enabled in the config)") }
        // Locked session: macOS refuses to move windows, the model would lie.
        guard !registry.isSessionLocked else { return completion("session locked, ignored") }
        let screens = Screens.all()
        guard !screens.isEmpty else { return completion("no screen") }
        let window = windowID.flatMap { registry.store.windows[$0] } ?? (windowID == nil ? registry.focusedWindow : nil)
        guard let window else { return completion(windowID.map { "unknown window \($0)" } ?? "no focused window") }
        let actions = state.move(window, to: target, windows: registry.store.orderedWindows, screens: screens)
        guard state.workspace(of: window.id) == target else { return completion("invalid workspace \(target)") }
        ignoreFocusUntil = .distantFuture
        persist()
        execute(actions, label: "\(source) move \(window.id) [\(window.appName)] → workspace \(target)") { [weak self] _ in
            self?.ignoreFocusUntil = Date().addingTimeInterval(0.4)
            completion("\(window.id) → workspace \(target)")
        }
    }

    // MARK: - Screens

    /// The screen the user works on: the focused window's, else the one under the mouse.
    private func focusedScreen(among screens: [Screen]) -> Screen? {
        if let window = registry.focusedWindow, !state.isHidden(window.id),
            let screen = LayoutEngine.screen(for: window.frame, among: screens)
        {
            return screen
        }
        return Screens.underMouse(among: screens) ?? screens.first
    }

    /// Fresh start (enabled, launch): each screen shows a workspace and every
    /// window joins the one of its screen. Nothing is parked at that point.
    private func regroup(reason: String) {
        let screens = Screens.all()
        let actions = state.restoreAll(screens: screens, windows: registry.store.orderedWindows)
        knownScreens = screens.map(\.id)
        persist()
        Log.info("workspaces (\(reason)): \(describeVisible(screens))")
        if !actions.isEmpty { execute(actions, label: "regroup") { _ in } }
    }

    /// Plugging or unplugging a screen: macOS first moves the windows of a lost
    /// screen, in several steps. Wait for it to settle, then update the model.
    private func screensDidChange() {
        screenChangeWork?.cancel()
        screenChanging = true
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.applyScreenChange() } }
        screenChangeWork = work
        // 3 s: a monitor going to sleep or losing its signal for a moment
        // comes back within that (seen at 2 s), and then nothing changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Between a screen notification and its handling (and 1 s after), the
    /// windows macOS moves around do not change workspace.
    private var screenChanging = false
    private var ignoreScreenMovesUntil = Date.distantPast

    private func applyScreenChange() {
        screenChanging = false
        ignoreScreenMovesUntil = Date().addingTimeInterval(1)
        let screens = Screens.all()
        let ids = screens.map(\.id)
        guard isEnabled, recoveryDone else { return }
        guard ids != knownScreens else {
            // Back as before: only the parked windows macOS moved meanwhile.
            let actions = state.repark(screens, windows: registry.store.orderedWindows)
            if !actions.isEmpty { execute(actions, label: "screens back as before, re-parked") { _ in } }
            return
        }
        let lost = knownScreens.filter { !ids.contains($0) }.count
        let added = ids.filter { !knownScreens.contains($0) }.count
        knownScreens = ids
        let actions = state.screensChanged(screens, windows: registry.store.orderedWindows)
        persist()
        execute(actions, label: "screens changed (+\(added) −\(lost)): \(describeVisible(screens))") { _ in }
    }

    private func describeVisible(_ screens: [Screen]) -> String {
        screens.enumerated().map { i, s in "screen\(i) → \(state.visible[s.id].map(String.init) ?? "?")" }.joined(separator: ", ")
    }

    /// Every parked window back on screen. Used by `pave restore-all` and on quit.
    /// The count includes windows the start-up recovery brought back, so
    /// `pave restore-all` after a crash reports them.
    public func restoreAll(source: String, completion: @escaping @MainActor (Int) -> Void = { _ in }) {
        guard recoveryDone else { return waitingForRecovery.append(completion) }
        let recovered = recoveredCount
        recoveredCount = 0
        // Screens always given: a frame saved on a screen that is gone is carried.
        let actions = state.restoreAll(screens: Screens.all(), windows: registry.store.orderedWindows)
        persist()
        guard !actions.isEmpty else { return completion(recovered) }
        execute(actions, label: "\(source) restore-all") { shown in completion(recovered + shown) }
    }

    // MARK: - Applying actions

    private func execute(_ actions: [Workspaces.Action], label: String, completion: @escaping @MainActor (_ shown: Int) -> Void) {
        let start = Date()
        var frames: [(WindowSnapshot, Rect)] = []
        var focus: WindowSnapshot?
        for action in actions {
            switch action {
            case .setFrame(let id, let rect):
                if let window = registry.store.windows[id] { frames.append((window, rect)) }
            case .focus(let id):
                focus = registry.store.windows[id]
            }
        }

        var remaining = frames.count
        var parked = 0, shown = 0, misses: [String] = []
        let finish = { [weak self] in
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            Log.info(
                "\(label): \(parked) parked, \(shown) shown, \(misses.count) miss\(misses.isEmpty ? "" : " [\(misses.joined(separator: ", "))]"), \(ms) ms"
            )
            if let focus { self.registry.focus(focus) }
            completion(shown)
        }
        guard remaining > 0 else { return finish() }

        for (window, target) in frames {
            let parking = state.isHidden(window.id)
            inFlight.insert(window.id)
            registry.setFrame(of: window, to: target) { [weak self] result in
                guard let self else { return }
                self.inFlight.remove(window.id)
                if parking {
                    parked += 1
                    if let actual = result.actual {
                        self.parkedAt[window.id] = actual
                        self.logParking(window, actual)
                    } else {
                        misses.append("\(window.id) \(result.error ?? "?")")
                    }
                } else {
                    shown += 1
                    self.parkedAt[window.id] = nil
                    if !result.ok { misses.append("\(window.id) [\(window.appName)] actual \(result.actual.map(\.description) ?? "?")") }
                }
                remaining -= 1
                if remaining == 0 { finish() }
            }
        }
    }

    /// W1: a parked window must not show on any screen beyond a 1 pt column
    /// (macOS may pull it up along its own screen's edge: that is fine).
    private func logParking(_ window: WindowSnapshot, _ actual: Rect) {
        for (i, screen) in Screens.all().enumerated() {
            let w = max(0, min(actual.maxX, screen.frame.maxX) - max(actual.x, screen.frame.x))
            let h = max(0, min(actual.maxY, screen.frame.maxY) - max(actual.y, screen.frame.y))
            if w > 1 && h > 1 {
                Log.info("W1 VISIBLE parked \(window.id) [\(window.appName)] at \(actual): \(Int(w))×\(Int(h)) pt on screen\(i)")
            }
        }
    }

    // MARK: - Registry changes

    private func handle(_ changes: [WindowChange]) {
        var dirty = false
        var actions: [Workspaces.Action] = []
        var focused: [WindowID] = []
        var retitled: [WindowID] = []
        let screens = isEnabled ? Screens.all() : []
        for change in changes {
            switch change {
            case .created(let window):
                guard registry.isReady else { break }
                if isEnabled, recoveryDone {
                    // App rule `workspace = N`: standard windows only, a dialog
                    // must never open on a hidden workspace.
                    let choice = window.subrole == "AXStandardWindow" ? workspaceRule(window) : AppRule.WorkspaceChoice()
                    let preferred = choice.workspace
                    let adopted = state.adopt(window, screens: screens, preferred: preferred)
                    if let preferred, !adopted.isEmpty || state.workspace(of: window.id) == preferred {
                        Log.info("\(window.id) [\(window.appName)] → workspace \(preferred) (\(choice.byProfile ? "profile" : "app") rule)")
                    }
                    if choice.awaitsTitle { awaitingTitle[window.id] = Date().addingTimeInterval(Self.titleWait) }
                    actions += adopted
                } else {
                    state.adopt(window.id)
                }
                dirty = true
            case .destroyed(let window):
                if state.isHidden(window.id) || state.assignment[window.id] != nil { dirty = true }
                state.forget(window.id)
                parkedAt[window.id] = nil
                awaitingTitle[window.id] = nil
            case .frameChanged(let id, _, let to):
                guard !inFlight.contains(id) else { break }
                if let spot = parkedAt[id] {
                    // macOS pulls parked windows up to keep their title bar on
                    // a screen (measured): only a sideways move is an escape.
                    if abs(to.x - spot.x) > 2 {
                        bounces += 1
                        let app = registry.store.windows[id]?.appName ?? "?"
                        Log.info("H4 BOUNCE \(id) [\(app)]: parked at \(spot), moved itself to \(to)")
                    }
                    parkedAt[id] = to
                } else if isEnabled, !screenChanging, Date() >= ignoreScreenMovesUntil,
                    state.windowMoved(id, to: to, screens: screens)
                {
                    let app = registry.store.windows[id]?.appName ?? "?"
                    Log.info("\(id) [\(app)] moved to another screen → workspace \(state.workspace(of: id))")
                    dirty = true
                }
            case .focused(let id):
                focused.append(id)
            case .stateChanged(let id, _, let to) where to == .normal:
                // Unhidden or restored: once the focus follow had its chance,
                // park it if its workspace is on no screen (⌘H).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    MainActor.assumeIsolated { self?.parkIfStray(id) }
                }
            case .retitled(let id, _, _):
                if awaitingTitle[id] != nil { retitled.append(id) }
            case .stateChanged(let id, _, .minimized):
                if let pid = registry.store.windows[id]?.pid { minimizedAt[pid] = Date() }
            case .stateChanged:
                break
            }
        }
        if dirty { persist() }
        if !actions.isEmpty { execute(actions, label: "new window(s)") { _ in } }
        // After the new windows' actions: a window opened by an app rule on a
        // hidden workspace and focused in the same batch was parked, then
        // shown by the switch. The other way round, the park (sent last)
        // left it in a corner while Pavé took it for shown. Moves of one app
        // run in order (AppConnection).
        for id in focused { followFocus(to: id) }
        for id in retitled { resolveProfile(id) }
    }

    /// How long a new window with no profile in its title is looked at again.
    static let titleWait: TimeInterval = 2
    /// New windows of an app with profile rules whose title named no profile
    /// yet, until when their titles are checked.
    private var awaitingTitle: [WindowID: Date] = [:]

    /// A window of an app with profile rules got a title (the profile, a
    /// moment after it opened): it goes to the profile's workspace.
    private func resolveProfile(_ id: WindowID) {
        guard let deadline = awaitingTitle[id] else { return }
        guard Date() < deadline, isEnabled, recoveryDone, !registry.isSessionLocked,
            let window = registry.store.windows[id]
        else { awaitingTitle[id] = nil; return }
        let choice = workspaceRule(window)
        guard choice.byProfile, let target = choice.workspace else { return }
        awaitingTitle[id] = nil
        guard target != state.workspace(of: id) else { return }
        let screens = Screens.all()
        let from = state.active
        let follow = registry.focusedWindow?.id == id
        let actions = state.ruleResolved(
            window, to: target, follow: follow, focusedScreen: focusedScreen(among: screens),
            screens: screens, windows: registry.store.orderedWindows)
        persist()
        ignoreFocusUntil = .distantFuture
        let shown = follow ? ", workspace \(from) → \(state.active)" : ""
        execute(actions, label: "\(id) [\(window.appName)] → workspace \(target) (profile rule, title came late)\(shown)") {
            [weak self] _ in self?.ignoreFocusUntil = Date().addingTimeInterval(0.4)
        }
    }

    private func parkIfStray(_ id: WindowID) {
        guard isEnabled, recoveryDone, !registry.isSessionLocked, let window = registry.store.windows[id] else { return }
        let actions = state.parkStray(window, screens: Screens.all())
        guard !actions.isEmpty else { return }
        persist()
        execute(actions, label: "\(id) [\(window.appName)] shown again on hidden workspace \(state.workspace(of: id)), parked") { _ in }
    }

    /// When Pavé itself last asked for a window's focus (FocusService): W3.
    public var paveRequestedFocus: (WindowID) -> Date? = { _ in nil }
    /// Focus given back after an ignored change (FocusService).
    public var refocus: (WindowSnapshot) -> Void = { _ in }
    private var lastRefocus = Date.distantPast
    public private(set) var ignoredFocusChanges = 0

    /// W3: a focus change is the user's will if they just pressed a key or
    /// clicked (⌘Tab, a notification, a link), or if Pavé asked for it.
    /// Otherwise macOS or the app moved the focus by itself (seen in M0: a
    /// parked window got it 1.4 s after a switch).
    private func isIntended(_ id: WindowID) -> Bool {
        if let asked = paveRequestedFocus(id), Date().timeIntervalSince(asked) < 2 { return true }
        // flagsChanged: releasing ⌘ ends a ⌘Tab that may have been browsed a while.
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let idle = types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        return idle < 1.5
    }

    /// Alt+Tab, ⌘Tab or a notification focused a window of another workspace: go there.
    private func followFocus(to id: WindowID) {
        guard isEnabled, recoveryDone, Date() >= ignoreFocusUntil, state.workspace(of: id) != state.active else { return }
        let screens = Screens.all()
        guard let focused = focusedScreen(among: screens) else { return }
        let from = state.active
        let wasVisible = state.isVisible(state.workspace(of: id))
        let app = registry.store.windows[id]?.appName ?? "?"
        // Minimizing an app's last window here: macOS hands the focus to its
        // next window, maybe on a hidden workspace. The user only put a
        // window away, they stay where they are.
        if !wasVisible, let pid = registry.store.windows[id]?.pid, let at = minimizedAt[pid],
            Date().timeIntervalSince(at) < Self.minimizeFocusWindow
        {
            Log.info("focus moved to \(id) [\(app)] of workspace \(state.workspace(of: id)) after a minimize, not followed")
            return giveFocusBack(from: id, throttled: false)
        }
        if !wasVisible, !isIntended(id) {
            ignoredFocusChanges += 1
            Log.info("W3: focus moved to \(id) [\(app)] of workspace \(state.workspace(of: id)) without the user, ignored (\(ignoredFocusChanges) so far)")
            return giveFocusBack(from: id, throttled: true)
        }
        let actions = state.focused(id, focusedScreen: focused, screens: screens, windows: registry.store.orderedWindows)
        persist()
        if wasVisible { return }  // another screen got the focus: nothing to move
        ignoreFocusUntil = .distantFuture
        execute(actions, label: "focus \(id) [\(app)] → workspace \(from) → \(state.active)") { [weak self] _ in
            self?.ignoreFocusUntil = Date().addingTimeInterval(0.4)
        }
    }

    /// How long after a minimize the app's focus moves are its own doing.
    static let minimizeFocusWindow: TimeInterval = 1
    /// When each app last had a window minimized.
    private var minimizedAt: [PID: Date] = [:]

    /// The focus goes back to the most recent shown window (`throttled`: at
    /// most every 2 s, against an app that keeps taking it).
    private func giveFocusBack(from id: WindowID, throttled: Bool) {
        guard !throttled || Date().timeIntervalSince(lastRefocus) > 2,
            let back = registry.store.orderedWindows.first(where: {
                $0.id != id && $0.state == .normal && !state.isHidden($0.id) && state.isVisible(state.workspace(of: $0.id))
            })
        else { return }
        lastRefocus = Date()
        refocus(back)
    }

    /// The app rule's workspace for a new window (`[apps."…"] workspace = N`,
    /// or its `profiles`).
    public var workspaceRule: (WindowSnapshot) -> AppRule.WorkspaceChoice = { _ in AppRule.WorkspaceChoice() }

    /// Called after every change of the state (taskbar numbers, tiling).
    private var changeObservers: [() -> Void] = []
    public func addChangeObserver(_ observer: @escaping () -> Void) { changeObservers.append(observer) }
    private func onChange() { changeObservers.forEach { $0() } }

    /// A parked window will come back at `frame` when its workspace shows.
    public func setReturnFrame(_ id: WindowID, _ frame: Rect) {
        state.setSavedFrame(id, frame)
        persist()
    }

    private func persist() {
        let names = registry.store.windows.mapValues(\.appName)
        store.save(state, appNames: names)
        onChange()
    }
}
