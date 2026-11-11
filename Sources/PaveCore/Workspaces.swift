/// Virtual workspaces: native Spaces are not used. Windows of inactive
/// workspaces are parked in a screen corner, their frame remembered.
///
/// One set of workspaces 1…9 for all screens: each screen shows one, and each
/// workspace belongs to the screen it was last shown on (its home). Win+N shows
/// N on its home screen, or just moves the focus there when N is already visible.
///
/// Pure value: decides *what* to do; PaveMac applies the actions and persists
/// the value after every change (crash recovery).
public struct Workspaces: Codable, Sendable, Equatable {
    public static let range = 1...9

    /// Workspace of the focused screen.
    public private(set) var active = 1
    /// Workspace shown on each screen, by `Screen.id`. Empty until the first
    /// `screensChanged` (single-screen callers never need it).
    public private(set) var visible: [String: Int] = [:]
    /// Screen each workspace was last shown on.
    public private(set) var home: [Int: String] = [:]
    /// Explicit workspace of each window. A window absent from it belongs to
    /// the active workspace (new windows open where the user is).
    public private(set) var assignment: [WindowID: Int] = [:]
    /// Frame to restore for every parked (hidden) window.
    public private(set) var savedFrames: [WindowID: Rect] = [:]
    /// What each unplugged screen had, given back if it returns (a monitor
    /// that sleeps or loses its signal comes back seconds later).
    public private(set) var departed: [String: Departed] = [:]

    public struct Departed: Codable, Sendable, Equatable {
        /// The workspace it showed.
        public var visible: Int
        /// The workspaces that lived on it.
        public var homes: [Int]
        /// Its shown windows, which joined the remaining screen's workspace.
        public var windows: [WindowID]
    }

    public init() {}

    // Older state files have only active / assignment / savedFrames.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decode(Int.self, forKey: .active)
        visible = try c.decodeIfPresent([String: Int].self, forKey: .visible) ?? [:]
        home = try c.decodeIfPresent([Int: String].self, forKey: .home) ?? [:]
        assignment = try c.decode([WindowID: Int].self, forKey: .assignment)
        savedFrames = try c.decode([WindowID: Rect].self, forKey: .savedFrames)
        departed = try c.decodeIfPresent([String: Departed].self, forKey: .departed) ?? [:]
    }

    public enum Action: Equatable, Sendable {
        case setFrame(WindowID, Rect)
        case focus(WindowID)
    }

    public func workspace(of id: WindowID) -> Int { assignment[id] ?? active }
    public func isHidden(_ id: WindowID) -> Bool { savedFrames[id] != nil }
    /// Parked, or of a workspace shown on no screen: minimized windows are
    /// never parked but belong to their workspace, the taskbar lists them there only.
    public func isOutOfSight(_ id: WindowID) -> Bool { isHidden(id) || !isVisible(workspace(of: id)) }

    /// A parked window will come back at `frame` (an arrangement placed it).
    public mutating func setSavedFrame(_ id: WindowID, _ frame: Rect) {
        guard savedFrames[id] != nil else { return }
        savedFrames[id] = frame
    }
    public var hiddenCount: Int { savedFrames.count }

    /// Workspaces shown right now, one per screen.
    public var visibleWorkspaces: Set<Int> { visible.isEmpty ? [active] : Set(visible.values) }
    public func isVisible(_ n: Int) -> Bool { visibleWorkspaces.contains(n) }
    /// The screen showing workspace `n`, if any.
    public func screen(showing n: Int) -> String? { visible.first { $0.value == n }?.key }

    // MARK: - Screens

    /// Start-up, screen plugged or unplugged. The windows shown on a screen
    /// that went away stay visible, as on Windows and macOS:
    /// macOS moved them to a remaining screen, they join the workspace shown
    /// there. Hidden windows of that workspace stay hidden, and the workspace
    /// moves to the primary screen, like every workspace whose home went away.
    /// Every parked window is parked again for the new arrangement (macOS moved
    /// those too). A new screen shows an empty workspace. `screens[0]` is the
    /// primary one.
    public mutating func screensChanged(_ screens: [Screen], windows: [WindowSnapshot]) -> [Action] {
        guard let primary = screens.first else { return [] }
        let ids = Set(screens.map(\.id))
        var actions: [Action] = []

        let lost = visible.filter { !ids.contains($0.key) }
        for (sid, n) in lost {
            visible[sid] = nil
            departed[sid] = Departed(
                visible: n, homes: home.filter { $0.value == sid }.map(\.key).sorted(),
                windows: windows.filter { workspace(of: $0.id) == n && $0.state == .normal && !isHidden($0.id) }.map(
                    \.id))
        }
        for (n, sid) in home where !ids.contains(sid) { home[n] = primary.id }

        var returned: [(Screen, Departed)] = []
        for screen in screens where visible[screen.id] == nil {
            var n = nextFreeWorkspace(for: screen.id, windows: windows)
            if let back = departed.removeValue(forKey: screen.id) {
                // It came back: its workspaces go home, unless shown elsewhere meanwhile.
                for h in back.homes where !isVisible(h) { home[h] = screen.id }
                if !isVisible(back.visible) { n = back.visible }
                returned.append((screen, back))
            }
            visible[screen.id] = n
            home[n] = screen.id
            actions += show(n, on: screen, screens: screens, windows: windows)
        }
        if !isVisible(active) { active = visible[primary.id] ?? Self.range.lowerBound }

        let lostWorkspaces = Set(lost.values)
        for window in windows where !isHidden(window.id) && lostWorkspaces.contains(workspace(of: window.id)) {
            assignment[window.id] = workspaceShown(at: window.frame, screens: screens)
        }
        // Windows macOS put back on a returning screen rejoin its workspace.
        for (screen, back) in returned {
            for window in windows
            where back.windows.contains(window.id) && !isHidden(window.id)
                && LayoutEngine.screen(for: window.frame, among: screens)?.id == screen.id
            {
                assignment[window.id] = visible[screen.id]
            }
        }
        actions += repark(screens, windows: windows, except: actions)
        return actions
    }

    /// Planned restart of Pavé (`just install`, an update): the previous run
    /// left its windows parked on purpose, so this one carries on with its
    /// state instead of bringing everything back. Windows gone meanwhile are
    /// forgotten, new ones join the workspace shown on their screen, a changed
    /// set of screens is handled as usual, and a window shown although its
    /// workspace is not is parked.
    /// `alive`: windows that still exist, seen or not (an app slow to answer
    /// at start-up must not lose its parked windows); nil: `windows` only.
    public mutating func resume(screens: [Screen], windows: [WindowSnapshot], alive: Set<WindowID>? = nil) -> [Action] {
        let present = alive ?? Set(windows.map(\.id))
        for id in Set(assignment.keys).union(savedFrames.keys) where !present.contains(id) { forget(id) }
        var actions = screensChanged(screens, windows: windows)
        for window in windows where assignment[window.id] == nil { actions += adopt(window, screens: screens) }
        for window in windows { actions += parkStray(window, screens: screens) }
        return actions
    }

    /// Parked windows macOS moved (screen change) are parked again at a safe
    /// spot. `except`: windows already given a frame.
    public func repark(_ screens: [Screen], windows: [WindowSnapshot], except: [Action] = []) -> [Action] {
        let moved = Set(except.compactMap { if case .setFrame(let id, _) = $0 { id } else { nil } })
        return windows.compactMap { window in
            guard isHidden(window.id), !moved.contains(window.id),
                let screen = LayoutEngine.screen(for: window.frame, among: screens),
                let spot = ParkingSpot.park(window.frame, on: screen, among: screens),
                abs(spot.x - window.frame.x) > 2
            else { return nil }
            // Already at another safe corner: leave it.
            if screens.contains(where: { s in
                [ParkingSpot.Corner.bottomRight, .bottomLeft].contains { c in
                    ParkingSpot.isSafe(c, of: s, among: screens, windowSize: window.frame)
                        && abs(ParkingSpot.frame(for: window.frame, at: c, of: s).x - window.frame.x) <= 2
                }
            }) {
                return nil
            }
            return .setFrame(window.id, spot)
        }
    }

    /// For a screen without a workspace: the active one when nothing is shown
    /// yet (start-up), else one that lives there, else the lowest empty one.
    private func nextFreeWorkspace(for sid: String, windows: [WindowSnapshot]) -> Int {
        if visible.isEmpty { return active }
        let shown = Set(visible.values)
        if let n = Self.range.first(where: { home[$0] == sid && !shown.contains($0) }) { return n }
        let used = Set(windows.map { workspace(of: $0.id) }).union(assignment.values)
        return Self.range.first { !shown.contains($0) && !used.contains($0) && home[$0] == nil }
            ?? Self.range.first { !shown.contains($0) }
            ?? Self.range.lowerBound
    }

    // MARK: - Windows

    /// A window was opened (or found at start-up): it joins the workspace shown
    /// on its screen, or `preferred` (app rule `workspace = N`), which may send
    /// it to another screen or park it at once.
    public mutating func adopt(_ window: WindowSnapshot, screens: [Screen], preferred: Int? = nil) -> [Action] {
        guard assignment[window.id] == nil else { return [] }
        let here = workspaceShown(at: window.frame, screens: screens)
        assignment[window.id] = here
        guard let preferred, Self.range.contains(preferred), preferred != here else { return [] }
        return move(window, to: preferred, windows: [], screens: screens, focusNext: false)
    }

    /// The app rule's workspace of a window became known after it opened (a
    /// browser titles its window with the profile a moment later). `follow`:
    /// the user has it in front, so its workspace is shown, as when the focus
    /// follows a new window; else it is sent there like Win+Shift+N.
    public mutating func ruleResolved(
        _ window: WindowSnapshot, to target: Int, follow: Bool, focusedScreen: Screen?,
        screens: [Screen], windows: [WindowSnapshot]
    ) -> [Action] {
        var actions = move(window, to: target, windows: windows, screens: screens, focusNext: !follow)
        guard follow, let focusedScreen, workspace(of: window.id) == target else { return actions }
        actions += switchTo(target, focusedScreen: focusedScreen, screens: screens, windows: windows)
        return actions
    }

    /// Single-screen form, kept for callers that do not know about screens.
    public mutating func adopt(_ id: WindowID) {
        if assignment[id] == nil { assignment[id] = active }
    }

    /// A window was closed.
    public mutating func forget(_ id: WindowID) {
        assignment[id] = nil
        savedFrames[id] = nil
    }

    /// A shown window moved (drag, Win+Shift+arrow, macOS after a re-plug):
    /// it now belongs to the workspace of the screen holding it. True if that
    /// changed its workspace.
    @discardableResult
    public mutating func windowMoved(_ id: WindowID, to frame: Rect, screens: [Screen]) -> Bool {
        guard !isHidden(id), !visible.isEmpty else { return false }
        let here = workspaceShown(at: frame, screens: screens)
        guard here != workspace(of: id) else { return false }
        assignment[id] = here
        return true
    }

    private func workspaceShown(at frame: Rect, screens: [Screen]) -> Int {
        guard let screen = LayoutEngine.screen(for: frame, among: screens) else { return active }
        return visible[screen.id] ?? active
    }

    // MARK: - Commands

    /// Win+N. `focusedScreen` is used when N has no home yet (or its home is
    /// gone). `windows` in MRU order (most recent first).
    public mutating func switchTo(
        _ target: Int, focusedScreen: Screen, screens: [Screen], windows: [WindowSnapshot]
    ) -> [Action] {
        guard Self.range.contains(target), target != active || !isVisible(target) else { return [] }
        if isVisible(target) {
            // Already on a screen: only the focus moves there.
            active = target
            return focusAction(in: target, windows: windows)
        }
        let all = screens.isEmpty ? [focusedScreen] : screens
        let screen = home[target].flatMap { sid in all.first { $0.id == sid } } ?? focusedScreen
        let outgoing = visible[screen.id] ?? active
        var actions: [Action] = []
        for window in windows where workspace(of: window.id) == outgoing {
            // Minimized windows stay attached to the workspace, without parking.
            assignment[window.id] = outgoing
            if window.state == .normal, !isHidden(window.id) {
                actions += park(window, screens: all, preferring: screen)
            }
        }
        actions += show(target, on: screen, screens: all, windows: windows)
        visible[screen.id] = target
        home[target] = screen.id
        active = target
        return actions + focusAction(in: target, windows: windows)
    }

    /// `pave workspace N --screen S`: shows N on `screen`, which becomes its
    /// home. Hidden: as a switch, on that screen. Shown on another screen:
    /// its windows move over (frames carried), and the screen it leaves
    /// shows another workspace (one that lives there, else an empty one).
    public mutating func display(_ target: Int, on screen: Screen, screens: [Screen], windows: [WindowSnapshot])
        -> [Action]
    {
        guard Self.range.contains(target), screens.contains(where: { $0.id == screen.id }) else { return [] }
        guard let from = self.screen(showing: target), from != screen.id else {
            if visible[screen.id] == target {
                active = target
                return focusAction(in: target, windows: windows)
            }
            home[target] = screen.id
            return switchTo(target, focusedScreen: screen, screens: screens, windows: windows)
        }
        var actions: [Action] = []
        let outgoing = visible[screen.id] ?? active
        for window in windows where workspace(of: window.id) == outgoing {
            assignment[window.id] = outgoing
            if window.state == .normal, !isHidden(window.id) {
                actions += park(window, screens: screens, preferring: screen)
            }
        }
        let old = screens.first { $0.id == from }
        for window in windows
        where workspace(of: window.id) == target && window.state == .normal && !isHidden(window.id) {
            assignment[window.id] = target
            let frame =
                old.map { LayoutEngine.carry(window.frame, from: $0.visibleFrame, to: screen.visibleFrame) }
                ?? window.frame
            actions.append(.setFrame(window.id, frame))
        }
        visible[screen.id] = target
        home[target] = screen.id
        visible[from] = nil
        if let old {
            let n = nextFreeWorkspace(for: from, windows: windows)
            visible[from] = n
            home[n] = from
            actions += self.show(n, on: old, screens: screens, windows: windows)
        }
        active = target
        return actions + focusAction(in: target, windows: windows)
    }

    /// Single-screen form.
    public mutating func switchTo(_ target: Int, windows: [WindowSnapshot], screen: Screen) -> [Action] {
        switchTo(target, focusedScreen: screen, screens: [screen], windows: windows)
    }

    /// Win+Shift+N: sends `window` to workspace `target`. Visible on another
    /// screen: the window moves there. Hidden: it is parked, and the focus goes
    /// to the next window of the workspace it left. `windows` in MRU order.
    public mutating func move(
        _ window: WindowSnapshot, to target: Int, windows: [WindowSnapshot], screens: [Screen]
    ) -> [Action] {
        move(window, to: target, windows: windows, screens: screens, focusNext: true)
    }

    /// Single-screen form.
    public mutating func move(
        _ window: WindowSnapshot, to target: Int, windows: [WindowSnapshot], screen: Screen
    ) -> [Action] {
        move(window, to: target, windows: windows, screens: [screen])
    }

    private mutating func move(
        _ window: WindowSnapshot, to target: Int, windows: [WindowSnapshot], screens: [Screen], focusNext: Bool
    ) -> [Action] {
        let source = workspace(of: window.id)
        guard Self.range.contains(target), target != source else { return [] }
        assignment[window.id] = target
        guard !isHidden(window.id) else { return [] }

        if isVisible(target) {
            guard window.state == .normal, let sid = screen(showing: target),
                let to = screens.first(where: { $0.id == sid }),
                let from = LayoutEngine.screen(for: window.frame, among: screens), from.id != to.id
            else { return [] }
            return [
                .setFrame(window.id, LayoutEngine.carry(window.frame, from: from.visibleFrame, to: to.visibleFrame))
            ]
        }

        var actions: [Action] = []
        if window.state == .normal {
            let current = LayoutEngine.screen(for: window.frame, among: screens)
            if home[target] == nil, let current { home[target] = current.id }
            actions += park(window, screens: screens, preferring: current)
            // Restored later on the target's home screen: carry the frame there now.
            if let current, let homeScreen = screens.first(where: { $0.id == home[target] }),
                homeScreen.id != current.id
            {
                savedFrames[window.id] = LayoutEngine.carry(
                    window.frame, from: current.visibleFrame, to: homeScreen.visibleFrame)
            }
        }
        if focusNext,
            let next = windows.first(where: {
                $0.id != window.id && workspace(of: $0.id) == source && $0.state == .normal && !isHidden($0.id)
            })
        {
            actions.append(.focus(next.id))
        }
        return actions
    }

    /// The user focused `id` (Alt+Tab, ⌘Tab, notification…): follow it to its
    /// workspace. On another visible screen, only the active workspace changes.
    public mutating func focused(
        _ id: WindowID, focusedScreen: Screen, screens: [Screen], windows: [WindowSnapshot]
    ) -> [Action] {
        let target = workspace(of: id)
        guard target != active else { return [] }
        if isVisible(target) {
            active = target
            return []
        }
        return switchTo(target, focusedScreen: focusedScreen, screens: screens, windows: windows)
            .filter { if case .focus = $0 { false } else { true } }
    }

    /// Single-screen form.
    public mutating func focused(_ id: WindowID, windows: [WindowSnapshot], screen: Screen) -> [Action] {
        focused(id, focusedScreen: screen, screens: [screen], windows: windows)
    }

    /// Emergency exit: every parked window back where it was, a fresh start
    /// (also used when workspaces are turned off). With `screens`, each screen
    /// then shows a workspace again and every window joins the one of its screen.
    public mutating func restoreAll(screens: [Screen] = [], windows: [WindowSnapshot] = []) -> [Action] {
        // A frame saved on a screen that is gone is carried onto the primary one,
        // else macOS leaves the window almost entirely off screen.
        let restored = savedFrames.mapValues { frame in
            guard let primary = screens.first,
                !screens.contains(where: { $0.frame.intersectionArea(with: frame) >= frame.area / 2 })
            else { return frame }
            return LayoutEngine.carry(frame, from: frame, to: primary.visibleFrame)
        }
        let actions = restored.sorted { $0.key < $1.key }.map { Action.setFrame($0.key, $0.value) }
        savedFrames.removeAll()
        assignment.removeAll()
        visible.removeAll()
        home.removeAll()
        departed.removeAll()
        active = Self.range.lowerBound
        if !screens.isEmpty {
            _ = screensChanged(screens, windows: [])
            for window in windows {
                assignment[window.id] = workspaceShown(at: restored[window.id] ?? window.frame, screens: screens)
            }
        }
        return actions
    }

    /// A window shown again (app unhidden, window restored) while its
    /// workspace is on no screen: it must not stay in sight on another one.
    public mutating func parkStray(_ window: WindowSnapshot, screens: [Screen]) -> [Action] {
        guard window.state == .normal, !isHidden(window.id), !visible.isEmpty, !isVisible(workspace(of: window.id))
        else { return [] }
        assignment[window.id] = workspace(of: window.id)
        return park(window, screens: screens)
    }

    // MARK: - Parking

    /// Parks `window` (frame saved), on `preferring` when one of its corners is
    /// safe, else wherever ParkingSpot finds a safe corner. With no safe corner
    /// at all, the legacy bottom-right corner (logged by the caller as visible).
    private mutating func park(_ window: WindowSnapshot, screens: [Screen], preferring: Screen? = nil) -> [Action] {
        guard let screen = preferring ?? LayoutEngine.screen(for: window.frame, among: screens) else { return [] }
        savedFrames[window.id] = window.frame
        let spot =
            ParkingSpot.park(window.frame, on: screen, among: screens)
            ?? Self.hiddenFrame(for: window.frame, on: screen)
        return [.setFrame(window.id, spot)]
    }

    /// Brings back the parked windows of `n` onto `screen`. A frame saved on
    /// another screen (one that went away) is carried onto this one.
    private mutating func show(_ n: Int, on screen: Screen, screens: [Screen], windows: [WindowSnapshot]) -> [Action] {
        var actions: [Action] = []
        for window in windows where workspace(of: window.id) == n {
            guard var frame = savedFrames.removeValue(forKey: window.id) else { continue }
            if screen.frame.intersectionArea(with: frame) < frame.area / 2 {
                let from = LayoutEngine.screen(for: frame, among: screens)
                frame = LayoutEngine.carry(
                    frame, from: from.map(\.visibleFrame) ?? frame, to: screen.visibleFrame)
            }
            actions.append(.setFrame(window.id, frame))
        }
        return actions
    }

    private func focusAction(in n: Int, windows: [WindowSnapshot]) -> [Action] {
        windows.first { workspace(of: $0.id) == n && $0.state == .normal }.map { [.focus($0.id)] } ?? []
    }

    /// Legacy parking spot: bottom-right corner, 1 pt left on screen.
    /// Size unchanged. Safe on a single screen; ParkingSpot picks among corners.
    public static func hiddenFrame(for frame: Rect, on screen: Screen) -> Rect {
        Rect(x: screen.frame.maxX - 1, y: screen.frame.maxY - 1, width: frame.width, height: frame.height)
    }
}
