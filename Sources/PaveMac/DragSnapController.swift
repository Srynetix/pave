import AppKit
import PaveCore

/// Snap by dragging a window to a screen edge.
///
/// The AX frame lags ~150 ms behind a drag, so it is never
/// used while dragging. Instead:
/// - **at the click**, the window under the cursor is identified with
///   `CGWindowListCopyWindowInfo` (bounds and IDs only, never titles);
/// - **while dragging**, its live bounds tell a move (origin changes, size
///   does not) from a resize or a click; the zone follows the cursor;
/// - **at the release**, AX places the window (Commander), then the frame is
///   read back 500 ms later, with one retry.
///
/// A window that was placed gets its size back as soon as it moves.
/// ⌥ held: no zone, the window is just moved.
///
/// On a screen that has a zone layout, its zones replace the edges: the
/// zone under the cursor is the target, ⇧ spans from the zone targeted before
/// it to the one under the cursor.
///
/// Elsewhere, a window dropped near another one's edge sticks to it
/// (magnetism), and resizing by a shared edge resizes the neighbour too
/// (DragSnapController+Magnet).
@MainActor
public final class DragSnapController {
    struct Press {
        var downAt: UInt64
        var downX: Double, downY: Double
        var window: WindowID?
        /// App under the click: a window it creates during the press (a tab
        /// dragged out of a browser) may become the dragged one.
        var pid: Int32?
        var startBounds: Rect?
        var lastProbeAt: UInt64 = 0
        /// First drag event: the detection delay counts from here (not from the click).
        var firstDragAt: UInt64?
        var detectedAt: UInt64?
        var zone: SnapZones.Zone?
        var resize = false
        /// Zones targeted on a screen that has a layout (instead of `zone`).
        var zoneTarget: ZoneTarget?
        /// Zone layout of each screen met during the press (looked up once).
        var layouts: [String: ScreenZones?] = [:]
        /// The screens, read at the first move (not at every event).
        var screens: [Screen]?
        /// Zone frames of the screen under the cursor, by screen and layout.
        var zoneFrames: (key: String, frames: [Rect])?
        /// The window was created during the press (not the clicked one).
        var adopted = false
        var counted = false
        /// ⌥ at the last move: no zone, no magnet, no neighbour.
        var option = false
        /// The window's frame at the click, or the size given back when it
        /// was placed: it follows the cursor from there.
        var base: Rect?
        /// Where the magnet puts it, while it differs from the cursor's place.
        var magnet: Rect?
        /// Windows sharing an edge with a resized one (found once).
        var neighbours: [Magnet.Neighbour]?
        var lastFollowAt: UInt64 = 0
        /// The cursor at the last move (the release has no use for its own).
        var cursor: (x: Double, y: Double)?
    }

    struct ZoneTarget: Equatable {
        var screen: Screen
        var layoutName: String
        /// The span starts here (the zone targeted before ⇧).
        var anchor: Int
        var zones: [Int]
        var frame: Rect
    }

    /// Set by the app: nil for a screen without zones.
    public var screenZones: (Screen) -> ScreenZones? = { _ in nil }

    let registry: WindowRegistry
    let commander: Commander
    private let zones = SnapZones()
    let preview = SnapPreview()
    private let overlay = ZonesOverlay()
    var press: Press?
    /// Neighbours with a move under way (one at a time each).
    var following: Set<WindowID> = []
    /// Points: magnet distance (0: off); resize by shared edges.
    public var magnetDistance: Double = 12
    public var resizeNeighbours = true
    public var magnetFill = true
    /// Shown on a screen (not parked, workspace visible): set by the app.
    public var isShown: (WindowID) -> Bool = { _ in true }
    private var detectionDelays = Samples()
    private var drops: (ok: Int, retried: Int, missed: Int) = (0, 0, 0)

    static let verifyDelay: TimeInterval = 0.5
    /// How often the window under the cursor is looked up again during a press.
    static let probeInterval: UInt64 = 40_000_000

    public init(registry: WindowRegistry, commander: Commander) {
        self.registry = registry
        self.commander = commander
    }

    public func handle(_ event: HotkeyService.MouseEvent) {
        switch event {
        case .down(let x, let y, let at):
            registry.quietFrameChanges = true
            var new = Press(downAt: at, downX: x, downY: y)
            if let (id, pid, bounds) = Self.windowUnder(x: x, y: y), isSnappable(id) {
                new.window = id
                new.pid = pid
                new.startBounds = bounds
            }
            press = new
        case .dragged(let x, let y, let option, let shift, let control, let at):
            dragged(x: x, y: y, option: option, shift: shift, control: control, at: at)
        case .up:
            registry.quietFrameChanges = false
            preview.hide()
            overlay.hide()
            guard let done = press else { return }
            press = nil
            released(done)
        }
    }

    /// Tiled windows are dropped on tiles, not snapped.
    public var isTiled: (WindowID) -> Bool = { _ in false }

    private func isSnappable(_ id: WindowID) -> Bool {
        guard let window = registry.store.windows[id], window.state == .normal, !registry.isSessionLocked,
            !isTiled(id)
        else { return false }
        // Dialogs, sheets and panels are never placed, and app rules apply.
        return commander.rule(window).refusal(for: window, via: .drag) == nil
    }

    private func dragged(x: Double, y: Double, option: Bool, shift: Bool, control: Bool, at: UInt64) {
        guard var current = press, current.window != nil else { return }
        current.option = option
        current.cursor = (x, y)
        if current.resize {
            followResize(&current, at: at)
            press = current
            return
        }
        if current.firstDragAt == nil { current.firstDragAt = at }
        defer { press = current }
        // Chromium recreates a dragged-out tab's window as it goes: follow the new one.
        if current.detectedAt != nil, at - current.lastProbeAt >= Self.probeInterval {
            current.lastProbeAt = at
            if Self.bounds(of: current.window!) == nil {
                preview.hide()
                overlay.hide()
                current.detectedAt = nil
                current.zone = nil
                current.zoneTarget = nil
            }
        }
        if current.detectedAt == nil {
            adoptNewWindow(&current, x: x, y: y, at: at)
            guard let id = current.window, let start = current.startBounds, let now = Self.bounds(of: id) else {
                return
            }
            if abs(now.width - start.width) > 1 || abs(now.height - start.height) > 1 {
                // A resize by an edge: not ours. (A window adopted mid-press may
                // still be settling its size: only the clicked one counts.)
                if current.adopted {
                    current.startBounds = now
                } else {
                    current.resize = true
                    followResize(&current, at: at)
                }
                return
            }
            guard abs(now.x - start.x) >= 2 || abs(now.y - start.y) >= 2 else { return }
            current.detectedAt = at
            if !current.counted {
                current.counted = true
                detectionDelays.append(Double(at - (current.firstDragAt ?? at)) / 1_000_000)
            }
            current.base = start
            if !current.adopted {
                if let restored = unsnapIfPlaced(
                    id, cursorX: x, cursorY: y, downX: current.downX, downY: current.downY, start: start)
                {
                    current.base = restored
                }
            }
        }
        guard let id = current.window else { return }
        let screens = current.screens ?? Screens.all()
        current.screens = screens
        // A screen with a layout: its zones replace the edges (Z-a).
        if let screen = Self.screen(atX: x, y: y, among: screens), let zones = layout(of: screen, in: &current) {
            if current.zone != nil {
                preview.hide()
                current.zone = nil
            }
            guard !option, !zones.needsControl || control else {
                overlay.hide()
                current.zoneTarget = nil
                showMagnet(&current, x: x, y: y, screens: screens)  // zones hidden: a free move
                return
            }
            if current.magnet != nil {
                preview.hide()
                current.magnet = nil
            }
            let area = screen.visibleFrame
            let hovered = zones.layout.zone(atX: x, y: y, in: area)
            let previous = current.zoneTarget.flatMap {
                $0.screen == screen && $0.layoutName == zones.layout.name ? $0 : nil
            }
            let anchor = shift ? previous?.anchor ?? hovered : hovered
            let span = zones.layout.span(anchor, hovered, in: area, gaps: zones.gaps)
            current.zoneTarget = ZoneTarget(
                screen: screen, layoutName: zones.layout.name, anchor: anchor, zones: span.zones, frame: span.frame)
            let key = "\(screen.id) \(zones.layout.name)"
            if current.zoneFrames?.key != key {
                current.zoneFrames = (key, zones.layout.frames(in: area, gaps: zones.gaps))
            }
            overlay.show(area: area, frames: current.zoneFrames!.frames, lit: Set(span.zones), below: id)
            return
        }
        if current.zoneTarget != nil {
            overlay.hide()
            current.zoneTarget = nil
        }
        let zone = option ? nil : zones.zone(atX: x, y: y, screens: screens, current: current.zone)
        if zone != current.zone {
            if let zone { preview.show(zone.frame, below: id) } else { preview.hide() }
        }
        current.zone = zone
        if zone == nil { showMagnet(&current, x: x, y: y, screens: screens) } else { current.magnet = nil }
    }

    private func layout(of screen: Screen, in press: inout Press) -> ScreenZones? {
        if let known = press.layouts[screen.id] { return known }
        let zones = screenZones(screen)
        press.layouts[screen.id] = zones
        return zones
    }

    private static func screen(atX x: Double, y: Double, among screens: [Screen]) -> Screen? {
        screens.first { $0.frame.contains(x: x, y: y) }
    }

    /// While nothing moves yet, the window under the cursor may be a new one of
    /// the same app (tab dragged out): it becomes the candidate.
    private func adoptNewWindow(_ current: inout Press, x: Double, y: Double, at: UInt64) {
        guard at - current.lastProbeAt >= Self.probeInterval, let pid = current.pid else { return }
        current.lastProbeAt = at
        guard let (id, owner, bounds) = Self.windowUnder(x: x, y: y), owner == pid, id != current.window else { return }
        current.window = id
        current.startBounds = bounds
        current.adopted = true
    }

    /// A placed window gets its floating size back when dragged away: that
    /// frame, at the click's place, is returned.
    private func unsnapIfPlaced(
        _ id: WindowID, cursorX: Double, cursorY: Double, downX: Double, downY: Double, start: Rect
    ) -> Rect? {
        guard var window = registry.store.windows[id] else { return nil }
        window.frame = start  // the live bounds at the click, not the lagging AX frame
        guard let restored = commander.dragStarted(window, cursorX: downX, cursorY: downY) else { return nil }
        // The window already followed the cursor since the click.
        let target = Rect(
            x: restored.x + (cursorX - downX), y: restored.y + (cursorY - downY),
            width: restored.width, height: restored.height)
        registry.setFrame(of: window, to: target) { result in
            Log.info(
                "drag \(id) [\(window.appName)]: size given back \(start) → \(target), \(result.ok ? "ok" : "MISS")")
        }
        return restored
    }

    private func released(_ done: Press) {
        if done.resize { return resizeEnded(done) }
        guard let id = done.window, let detectedAt = done.detectedAt else { return }
        let app = registry.store.windows[id]?.appName ?? "?"
        let held = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - done.downAt) / 1_000_000
        let sorted = detectionDelays.sorted()
        let detection =
            "detected \(Int(Double(detectedAt - (done.firstDragAt ?? detectedAt)) / 1_000_000)) ms after the drag start "
            + "(D1 so far: n=\(sorted.count), p50 \(Int(sorted[sorted.count / 2])), max \(Int(sorted.last!)) ms)"
        let detail = detection + (done.adopted ? ", window created during the drag" : "")
        if let target = done.zoneTarget {
            return drop(id, in: .zones(target), detection: detail, held: held, attempt: 0)
        }
        guard let zone = done.zone else {
            if magnetDrop(done) { return }
            return Log.info("drag \(id) [\(app)]: moved, no zone, \(detection), held \(Int(held)) ms")
        }
        drop(id, in: .edge(zone), detection: detail, held: held, attempt: 0)
    }

    enum DropTarget {
        case edge(SnapZones.Zone)
        case zones(ZoneTarget)

        var label: String {
            switch self {
            case .edge(let zone): zone.placement.rawValue
            case .zones(let target):
                "zone " + target.zones.map { "\($0 + 1)" }.joined(separator: "+") + " of \(target.layoutName)"
            }
        }
    }

    /// The registry learns about a window ~50 ms after it appears (AX): a tab
    /// dragged out may not be known yet when it is dropped.
    private func drop(_ id: WindowID, in zone: DropTarget, detection: String, held: Double, attempt: Int) {
        guard var window = registry.store.windows[id] else {
            if attempt < 5, Self.bounds(of: id) != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.drop(id, in: zone, detection: detection, held: held, attempt: attempt + 1)
                    }
                }
            } else {
                Log.info("drag \(id): dropped in \(zone.label) but the window is unknown or gone")
            }
            return
        }
        let app = window.appName
        guard commander.rule(window).refusal(for: window, via: .drag) == nil else {
            return Log.info(
                "drag \(id) [\(app)]: not placed (\(commander.rule(window).refusal(for: window, via: .drag)!))")
        }
        if let live = Self.bounds(of: id) { window.frame = live }
        let started = Date()
        let completion: @MainActor (MoveResult?) -> Void = { [weak self] result in
            guard let self else { return }
            let applied = result.map { $0.ok ? "ok" : "MISS" } ?? "nothing to do"
            Log.info(
                "drag \(id) [\(app)] → \(zone.label): \(applied) in \(Int(Date().timeIntervalSince(started) * 1000)) ms, "
                    + "\(detection), held \(Int(held)) ms")
            guard let result else { return }
            self.verify(id, app: app, target: result.target, retried: false)
        }
        switch zone {
        case .edge(let edge): commander.drop(window, in: edge, completion: completion)
        case .zones(let target): commander.drop(window, inZones: target.frame, completion: completion)
        }
    }

    /// Is the window still where it was put, once the app has settled?
    private func verify(_ id: WindowID, app: String, target: Rect, retried: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.verifyDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let live = Self.bounds(of: id), var window = self.registry.store.windows[id] else {
                    return
                }
                let centered = LayoutEngine.centered(width: live.width, height: live.height, in: target)
                var seen = window
                seen.frame = live
                if live.isClose(to: target) || live.isClose(to: centered) || self.commander.isInItsZones(seen) {
                    if retried { self.drops.retried += 1 } else { self.drops.ok += 1 }
                    if retried {
                        Log.info("drag (D2) \(id) [\(app)]: ok after retry · \(self.summary)")
                    } else {
                        Log.info("drag (D2) \(id) [\(app)]: held at +500 ms · \(self.summary)")
                    }
                    return
                }
                if retried {
                    self.drops.missed += 1
                    return Log.info("drag (D2) \(id) [\(app)]: MISS, \(live) instead of \(target) · \(self.summary)")
                }
                Log.info("drag (D2) \(id) [\(app)]: moved by the app to \(live), retrying")
                window.frame = live
                self.registry.setFrame(of: window, to: target) { _ in
                    self.verify(id, app: app, target: target, retried: true)
                }
            }
        }
    }

    private var summary: String {
        let total = drops.ok + drops.retried + drops.missed
        return "D2 so far: \(drops.ok)/\(total) first try, \(drops.retried) after retry, \(drops.missed) miss"
    }

    // MARK: - Window server (bounds and IDs only)

    /// Frontmost normal-level window of another app containing the point.
    private static func windowUnder(x: Double, y: Double) -> (WindowID, Int32, Rect)? {
        let me = ProcessInfo.processInfo.processIdentifier
        let list =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {  // front to back
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                let owner = info[kCGWindowOwnerPID as String] as? Int32, owner != me,
                let number = info[kCGWindowNumber as String] as? UInt32,
                let bounds = rect(info), bounds.contains(x: x, y: y)
            else { continue }
            return (WindowID(number), owner, bounds)
        }
        return nil
    }

    static func bounds(of id: WindowID) -> Rect? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id.rawValue)) as? [[String: Any]]
        return list?.first.flatMap(rect)
    }

    private static func rect(_ info: [String: Any]) -> Rect? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
            let r = CGRect(dictionaryRepresentation: dict as CFDictionary)
        else { return nil }
        return Rect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }
}
