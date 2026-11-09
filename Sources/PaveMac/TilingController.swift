import AppKit
import PaveCore
import PaveIPC

/// Applies a `TilingTree` per tiled workspace to real windows. The tree
/// follows the standard windows living on the workspace;
/// a workspace shown on a screen is laid out in that screen's usable area.
///
/// - A window refusing its tile size twice floats, and so does a
///   window its app keeps moving back (more than 3 times in 10 s): no fight.
/// - Mouse, once the button is up: a resized window gives its new
///   size to the tree, a moved one swaps with the tile under the cursor (or
///   goes back to its own); ⌥ held at the release makes it float.
/// - Frames Pavé sets are its own (`inFlight`, `targets`): never a reaction to them.
@MainActor
public final class TilingController {
    public struct Settings: Equatable, Sendable {
        public var workspaces: Set<Int>
        public var gaps: Double
        public init(workspaces: Set<Int> = [], gaps: Double = 8) {
            self.workspaces = workspaces
            self.gaps = gaps
        }
    }

    struct Persisted: Codable {
        var trees: [Int: TilingTree]
        var floating: [WindowID]
    }

    private let registry: WindowRegistry
    private let workspaces: WorkspaceController
    private let focusService: FocusService
    public var rule: (WindowSnapshot) -> AppRule = { _ in AppRule() }
    public private(set) var settings = Settings()

    public private(set) var trees: [Int: TilingTree] = [:]
    /// Windows the user (or a refusal) made float on a tiled workspace.
    private var floating: Set<WindowID> = []
    /// Frame each window had before it was first tiled: given back when it floats.
    private var floatFrames: [WindowID: Rect] = [:]
    /// Last frame Pavé gave each tiled window.
    private var targets: [WindowID: Rect] = [:]
    private var inFlight: Set<WindowID> = []
    private var refusals: [WindowID: Int] = [:]
    private var fights: [WindowID: [Date]] = [:]
    /// Tiled windows the user is dragging or resizing (mouse button down).
    private var mouseActive: Set<WindowID> = []
    private var mouseTimer: Timer?
    /// Where a dragged tiled window will land, like the snap preview.
    private let preview = SnapPreview()
    private var syncPending = false
    /// When the event that caused the pending sync arrived.
    private var syncCause: Date?
    private var times = Samples()

    static var url: URL { StateFiles.url("tiling.json") }

    public init(registry: WindowRegistry, workspaces: WorkspaceController, focus: FocusService) {
        self.registry = registry
        self.workspaces = workspaces
        self.focusService = focus
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            trees = saved.trees
            floating = Set(saved.floating)
        }
        registry.addChangeObserver { [weak self] in self?.handle($0) }
        workspaces.addChangeObserver { [weak self] in self?.scheduleSync() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleSync(after: 1.6) } }
    }

    public func update(settings new: Settings) {
        guard new != settings else { return }
        let added = new.workspaces.subtracting(settings.workspaces)
        let removed = settings.workspaces.subtracting(new.workspaces)
        settings = new
        if !added.isEmpty || !removed.isEmpty {
            Log.info("tiling: workspaces \(new.workspaces.sorted().map(String.init).joined(separator: ", ")), gaps \(Int(new.gaps))")
        }
        // Workspaces leaving tiling: their windows get their floating frame back.
        for n in removed { untile(n) }
        scheduleSync()
    }

    public func isTiledWorkspace(_ n: Int) -> Bool { workspaces.isEnabled && settings.workspaces.contains(n) }
    public func isTiled(_ id: WindowID) -> Bool { trees.values.contains { $0.contains(id) } }

    /// Shape of each tree, for `pave dump` (IDs only).
    public var summary: [String: String] {
        Dictionary(uniqueKeysWithValues: trees.filter { !$0.value.isEmpty }.map { ("\($0.key)", $0.value.description) })
    }

    // MARK: - Membership and layout

    private func tileable(_ window: WindowSnapshot) -> Bool {
        let appRule = rule(window)
        // Minimized and hidden (⌘H) windows keep their place in the tree; only
        // the shown ones are laid out (see `sync`).
        // AX gives no subrole for the windows of a hidden app: their state decides.
        let standard = window.subrole == "AXStandardWindow" || window.state == .minimized
            || (window.state == .hidden && trees.values.contains { $0.contains(window.id) })
        // A panel without a minimize button (Open, Save, settings) floats.
        return standard && window.minimizable != false && window.state != .fullscreen && !appRule.ignore && appRule.tile
            && !floating.contains(window.id)
    }

    private func scheduleSync(after delay: TimeInterval = 0) {
        // The layout time counts from the event, or from the end of a deliberate wait.
        if syncCause == nil { syncCause = Date().addingTimeInterval(delay) }
        guard !syncPending else { return }
        syncPending = true
        // One pass for a burst of changes (an app opening three windows at once).
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    private func sync() {
        syncPending = false
        let cause = syncCause ?? Date()
        syncCause = nil
        guard workspaces.isEnabled, !registry.isSessionLocked, registry.isReady else { return }
        let state = workspaces.state
        let windows = registry.store.orderedWindows  // MRU
        let screens = Screens.all()
        for n in trees.keys where !settings.workspaces.contains(n) { trees[n] = nil }

        var placements: [(WindowSnapshot, Rect)] = []
        var recheck = false
        for n in settings.workspaces.sorted() {
            let homeScreen = state.home[n].flatMap { id in screens.first { $0.id == id } } ?? screens.first
            var tree = trees[n] ?? TilingTree(
                orientation: (homeScreen.map { $0.frame.width >= $0.frame.height } ?? true) ? .horizontal : .vertical)
            let members = windows.filter { tileable($0) && state.workspace(of: $0.id) == n }
            let ids = Set(members.map(\.id))
            for id in tree.windows where !ids.contains(id) {
                // Full screen: AX destroys the window, then lists it again
                // on its own Space with the same ID. It keeps its place,
                // out of the layout (`shown`), while it still exists.
                switch keepsPlace(id) {
                case .fullscreen: continue
                case .absent:
                    recheck = true
                    continue
                case .no: tree.remove(id)
                }
            }
            // New windows go after the most recent window already tiled.
            for window in members.reversed() where !tree.contains(window.id) {
                let anchor = windows.first { $0.id != window.id && tree.contains($0.id) }?.id
                if !state.isHidden(window.id) { floatFrames[window.id] = floatFrames[window.id] ?? window.frame }
                tree.insert(window.id, after: anchor)
            }
            trees[n] = tree
            guard let sid = state.screen(showing: n), let screen = screens.first(where: { $0.id == sid }) else { continue }
            for (id, frame) in shown(tree).frames(in: screen.visibleFrame, gaps: settings.gaps) {
                guard let window = registry.store.windows[id], !state.isHidden(id), !inFlight.contains(id),
                    !mouseActive.contains(id), !window.frame.isClose(to: frame)
                else { continue }
                placements.append((window, frame))
            }
        }
        persist()
        apply(placements, cause: cause)
        // A window kept while AX lost it: gone for good once the window
        // server forgets it too (a closed one), back if AX lists it again.
        if recheck { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in MainActor.assumeIsolated { self?.sync() } } }
    }

    private enum KeepPlace { case no, fullscreen, absent }

    /// When each tree window went missing from AX.
    private var missingSince: [WindowID: Date] = [:]

    private func keepsPlace(_ id: WindowID) -> KeepPlace {
        if let window = registry.store.windows[id] {
            missingSince[id] = nil
            return window.state == .fullscreen ? .fullscreen : .no
        }
        // While macOS moves it to its full-screen Space, the window server
        // may not list it either: 2 s of grace first.
        let since = missingSince[id] ?? Date()
        missingSince[id] = since
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id.rawValue)) as? [[String: Any]]
        if list?.isEmpty == false || Date().timeIntervalSince(since) < 2 { return .absent }
        missingSince[id] = nil
        return .no
    }

    /// The tree as laid out: minimized and hidden (⌘H) windows keep their
    /// place in `tree` but leave the area to the shown ones.
    private func shown(_ tree: TilingTree) -> TilingTree {
        var copy = tree
        for id in tree.windows where registry.store.windows[id]?.state != .normal { copy.remove(id) }
        return copy
    }

    private func apply(_ placements: [(WindowSnapshot, Rect)], cause: Date) {
        guard !placements.isEmpty else { return }
        var remaining = placements.count
        for (window, frame) in placements {
            inFlight.insert(window.id)
            targets[window.id] = frame
            registry.setFrame(of: window, to: frame) { [weak self] result in
                guard let self else { return }
                self.inFlight.remove(window.id)
                self.checkRefusal(window, frame, result)
                remaining -= 1
                if remaining == 0 { self.logTiming(placements.count, since: cause) }
            }
        }
    }

    /// Twice the wrong size, and the window floats.
    private func checkRefusal(_ window: WindowSnapshot, _ frame: Rect, _ result: MoveResult) {
        guard let actual = result.actual else { return }
        if abs(actual.width - frame.width) > 2 || abs(actual.height - frame.height) > 2 {
            refusals[window.id, default: 0] += 1
            if refusals[window.id]! >= 2 {
                refusals[window.id] = nil
                float(window.id, reason: "refuses its tile size (\(Int(actual.width))×\(Int(actual.height)) for \(Int(frame.width))×\(Int(frame.height))); rule tile = false to silence", restore: false)
                // At the size it insists on, but inside its screen: grown
                // from its tile, it may stick out onto the next one (Slack).
                if let screen = LayoutEngine.screen(for: frame, among: Screens.all()) {
                    let area = screen.visibleFrame
                    var inside = actual
                    inside.x = min(max(inside.x, area.x), area.maxX - inside.width)
                    inside.y = min(max(inside.y, area.y), area.maxY - inside.height)
                    if !inside.isClose(to: actual), let current = registry.store.windows[window.id] {
                        registry.setFrame(of: current, to: inside) { _ in }
                    }
                }
            } else {
                scheduleSync(after: 0.3)
            }
        } else {
            refusals[window.id] = nil
            targets[window.id] = actual
        }
    }

    /// Layout time: from the event to the last window in place.
    private func logTiming(_ count: Int, since cause: Date) {
        let ms = Date().timeIntervalSince(cause) * 1000
        times.append(ms)
        let sorted = times.sorted()
        Log.info(
            "tiling (A1): \(count) window(s) placed \(Int(ms)) ms after the change · n=\(sorted.count), "
                + "p50 \(Int(sorted[sorted.count / 2])) ms, p95 \(Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])) ms")
    }

    /// A workspace leaves tiling: its shown windows get their frame from before.
    private func untile(_ n: Int) {
        guard let tree = trees.removeValue(forKey: n) else { return }
        for id in tree.windows {
            guard let window = registry.store.windows[id], !workspaces.state.isHidden(id),
                let frame = floatFrames.removeValue(forKey: id)
            else { continue }
            registry.setFrame(of: window, to: frame) { _ in }
        }
        persist()
    }

    private func float(_ id: WindowID, reason: String, restore: Bool) {
        floating.insert(id)
        let app = registry.store.windows[id]?.appName ?? "?"
        Log.info("tiling: \(id) [\(app)] floats (\(reason))")
        if restore, let window = registry.store.windows[id], let frame = floatFrames.removeValue(forKey: id) {
            registry.setFrame(of: window, to: frame) { _ in }
        }
        targets[id] = nil
        scheduleSync()
    }

    // MARK: - Registry changes

    private func handle(_ changes: [WindowChange]) {
        var dirty = false
        for change in changes {
            switch change {
            case .created, .stateChanged:
                dirty = true
            case .destroyed(let window):
                floating.remove(window.id)
                floatFrames[window.id] = nil
                targets[window.id] = nil
                refusals[window.id] = nil
                fights[window.id] = nil
                dirty = true
            case .frameChanged(let id, _, let to):
                guard isTiled(id), !inFlight.contains(id), let target = targets[id], !to.isClose(to: target),
                    !workspaces.state.isHidden(id)
                else { break }
                if NSEvent.pressedMouseButtons != 0 {
                    // The user drags or resizes it: decide once the button is up.
                    mouseActive.insert(id)
                    watchMouse()
                } else {
                    appMoved(id)
                }
            case .retitled, .focused:
                break
            }
        }
        if dirty { scheduleSync() }
    }

    /// The app moved or resized a tiled window by itself: put it back, unless
    /// it insists (then it floats: never a loop).
    private func appMoved(_ id: WindowID) {
        let recent = (fights[id] ?? []).filter { Date().timeIntervalSince($0) < 10 } + [Date()]
        fights[id] = recent
        if recent.count > 3 {
            fights[id] = nil
            return float(id, reason: "its app keeps moving it", restore: false)
        }
        scheduleSync(after: 0.15)
    }

    private func watchMouse() {
        updatePreview()
        guard mouseTimer == nil else { return }
        // 50 ms: the preview follows the cursor; the release is seen at once.
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard NSEvent.pressedMouseButtons == 0 else { return self.updatePreview() }
                self.mouseTimer?.invalidate()
                self.mouseTimer = nil
                self.preview.hide()
                self.mouseReleased()
            }
        }
    }

    /// The tile under the cursor (the swap), else the window's own tile (it
    /// goes back there). Nothing while resizing or with ⌥ (it will float).
    private func updatePreview() {
        guard let id = mouseActive.first, let (frames, ownTile) = tiles(around: id),
            let window = registry.store.windows[id], let target = targets[id]
        else { return preview.hide() }
        let resizing = abs(window.frame.width - target.width) > 2 || abs(window.frame.height - target.height) > 2
        if resizing || NSEvent.modifierFlags.contains(.option) { return preview.hide() }
        let (x, y) = Self.cursor()
        let under = frames.first { $0.key != id && $0.value.contains(x: x, y: y) }?.value
        preview.show(under ?? ownTile, below: id)
    }

    /// The tile frames of the window's workspace, and its own tile.
    private func tiles(around id: WindowID) -> ([WindowID: Rect], Rect)? {
        let state = workspaces.state
        let n = state.workspace(of: id)
        guard let tree = trees[n], let sid = state.screen(showing: n),
            let screen = Screens.all().first(where: { $0.id == sid })
        else { return nil }
        let frames = shown(tree).frames(in: screen.visibleFrame, gaps: settings.gaps)
        guard let own = frames[id] else { return nil }
        return (frames, own)
    }

    /// The mouse pointer, in AX coordinates.
    private static func cursor() -> (Double, Double) {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return (Double(p.x), Double(primaryHeight - p.y))
    }

    /// Mouse resize or move of tiled windows, once the button is up.
    private func mouseReleased() {
        let ids = mouseActive
        mouseActive = []
        let state = workspaces.state
        let screens = Screens.all()
        for id in ids {
            guard let window = registry.store.windows[id], let target = targets[id],
                let n = Optional(state.workspace(of: id)), var tree = trees[n],
                let sid = state.screen(showing: n), let screen = screens.first(where: { $0.id == sid })
            else { continue }
            if NSEvent.modifierFlags.contains(.option) {
                float(id, reason: "⌥ held at the drop", restore: false)
                continue
            }
            let resized = abs(window.frame.width - target.width) > 2 || abs(window.frame.height - target.height) > 2
            if resized {
                tree.resized(id, from: target, to: window.frame, in: screen.visibleFrame, gaps: settings.gaps)
                Log.info("tiling: \(id) [\(window.appName)] resized with the mouse")
            } else {
                // Moved: swap with the tile under the cursor, else back to its own.
                let (x, y) = Self.cursor()
                let frames = shown(tree).frames(in: screen.visibleFrame, gaps: settings.gaps)
                if let other = frames.first(where: { $0.key != id && $0.value.contains(x: x, y: y) })?.key {
                    tree.swap(id, other)
                    Log.info("tiling: \(id) [\(window.appName)] swapped with \(other)")
                }
            }
            trees[n] = tree
            targets[id] = nil  // its new tile is set by the sync
        }
        scheduleSync()
    }

    // MARK: - Commands

    /// Win+arrows act on the tree when the window is tiled.
    public func handles(_ command: LayoutCommand, windowID: WindowID? = nil) -> Bool {
        guard [.snapLeft, .snapRight, .maximize, .restore].contains(command),
            let window = target(windowID)
        else { return false }
        return isTiled(window.id)
    }

    public func perform(_ command: LayoutCommand, windowID: WindowID? = nil, source: String) {
        guard let window = target(windowID) else { return }
        let direction: Direction = switch command {
        case .snapLeft: .left
        case .snapRight: .right
        case .maximize: .up
        default: .down
        }
        let n = workspaces.state.workspace(of: window.id)
        guard var tree = trees[n] else { return }
        let result = tree.move(window.id, direction)
        trees[n] = tree
        Log.info("\(source) tiling move \(window.id) [\(window.appName)] \(direction.rawValue): \(result)")
        if result == .atEdge, direction == .left || direction == .right {
            // As in the floating mode: the neighbour screen's workspace.
            let screens = Screens.all()
            if let here = LayoutEngine.screen(for: window.frame, among: screens),
                let next = LayoutEngine.neighbour(of: here, toLeft: direction == .left, among: screens),
                let target = workspaces.state.visible[next.id]
            {
                workspaces.move(window.id, to: target, source: "\(source) tiling")
            }
        }
        scheduleSync()
    }

    /// Win+Alt+arrow: the neighbour window by geometry, among the windows
    /// shown on every screen (tiled or not).
    public func focus(_ direction: Direction, source: String) {
        guard let window = registry.focusedWindow else { return }
        let state = workspaces.state
        let frames = Dictionary(uniqueKeysWithValues: registry.store.windows.values.filter {
            $0.state == .normal && $0.subrole == "AXStandardWindow" && !state.isHidden($0.id)
        }.map { ($0.id, $0.frame) })
        guard let next = TilingTree.neighbour(of: window.id, direction, frames: frames),
            let target = registry.store.windows[next]
        else { return Log.info("\(source) focus \(direction.rawValue): no window that way") }
        focusService.focus(target, source: "\(source) focus \(direction.rawValue)") { _ in }
    }

    public func resize(_ direction: Direction, source: String) {
        guard let window = registry.focusedWindow else { return }
        let n = workspaces.state.workspace(of: window.id)
        guard var tree = trees[n], tree.contains(window.id) else { return }
        tree.resize(window.id, direction)
        trees[n] = tree
        Log.info("\(source) tiling resize \(window.id) [\(window.appName)] \(direction.rawValue)")
        scheduleSync()
    }

    /// Win+Shift+Space. Returns what happened, for the CLI.
    @discardableResult
    public func toggleFloating(windowID: WindowID? = nil, source: String) -> String {
        guard let window = target(windowID) else { return "no focused window" }
        if isTiled(window.id) {
            float(window.id, reason: "\(source)", restore: true)
            return "\(window.id) floats"
        }
        guard isTiledWorkspace(workspaces.state.workspace(of: window.id)) else { return "this workspace is not tiled" }
        floating.remove(window.id)
        guard tileable(window) else { return "\(window.id) cannot be tiled (dialog or app rule)" }
        Log.info("tiling: \(window.id) [\(window.appName)] tiled again (\(source))")
        scheduleSync()
        return "\(window.id) tiled"
    }

    public func toggleOrientation(source: String) {
        guard let window = registry.focusedWindow else { return }
        let n = workspaces.state.workspace(of: window.id)
        guard var tree = trees[n], tree.contains(window.id) else { return }
        tree.toggleOrientation(of: window.id)
        trees[n] = tree
        scheduleSync()
    }

    private func target(_ id: WindowID?) -> WindowSnapshot? {
        id.flatMap { registry.store.windows[$0] } ?? (id == nil ? registry.focusedWindow : nil)
    }

    private func persist() {
        let saved = Persisted(trees: trees, floating: Array(floating))
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? StateFiles.write(data, to: Self.url)
    }
}
