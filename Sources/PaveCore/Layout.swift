/// Window placement commands. The arrow commands behave like Windows 11: what
/// they do depends on where the window already is.
public enum LayoutCommand: String, Codable, Sendable, CaseIterable {
    /// Win+←: left half; from the left half, the right half of the screen on the left.
    case snapLeft = "snap-left"
    case snapRight = "snap-right"
    /// Win+↑: from a half, its top quarter; else fill the usable area (not native full screen).
    case maximize
    /// Win+↓: from a half, its bottom quarter; from a top quarter, the half;
    /// from maximized, the frame before Pavé placed it; else minimize.
    case restore
    /// Win+Shift+←/→: the screen on the left/right, same place on it.
    case moveToScreenLeft = "move-to-screen-left"
    case moveToScreenRight = "move-to-screen-right"
}

/// Where Pavé can put a window on a screen.
public enum Placement: String, Sendable, CaseIterable, Codable {
    case left, right, topLeft, topRight, bottomLeft, bottomRight, maximized

    /// Frame inside `area`. Splits fall on integral boundaries, so halves and
    /// quarters tile the area without a gap.
    public func frame(in area: Rect) -> Rect {
        let leftWidth = (area.width / 2).rounded(.down)
        let topHeight = (area.height / 2).rounded(.down)
        let left = Rect(x: area.x, y: area.y, width: leftWidth, height: area.height)
        let right = Rect(x: area.x + leftWidth, y: area.y, width: area.width - leftWidth, height: area.height)
        func top(_ r: Rect) -> Rect { Rect(x: r.x, y: r.y, width: r.width, height: topHeight) }
        func bottom(_ r: Rect) -> Rect {
            Rect(x: r.x, y: r.y + topHeight, width: r.width, height: area.height - topHeight)
        }
        switch self {
        case .left: return left
        case .right: return right
        case .topLeft: return top(left)
        case .topRight: return top(right)
        case .bottomLeft: return bottom(left)
        case .bottomRight: return bottom(right)
        case .maximized: return area
        }
    }

    var isLeftSide: Bool { [.left, .topLeft, .bottomLeft].contains(self) }
    var isRightSide: Bool { [.right, .topRight, .bottomRight].contains(self) }

    /// Same height band on the other side: topRight ↔ topLeft, right ↔ left.
    var mirrored: Placement {
        switch self {
        case .left: .right
        case .right: .left
        case .topLeft: .topRight
        case .topRight: .topLeft
        case .bottomLeft: .bottomRight
        case .bottomRight: .bottomLeft
        case .maximized: .maximized
        }
    }
}

/// A display, in global AX coordinates (top-left origin of the primary screen).
public struct Screen: Equatable, Sendable, Codable {
    public var frame: Rect
    /// Area not covered by the menu bar and the Dock.
    public var visibleFrame: Rect
    /// Stable identity across launches and re-plugs (display UUID); "" when unknown.
    public var id: String

    public init(frame: Rect, visibleFrame: Rect, id: String = "") {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.id = id
    }
}

public enum LayoutAction: Equatable, Sendable {
    case setFrame(Rect)
    case minimize
    case none(reason: String)
}

/// Pure placement logic: decides where a window goes; applying it is PaveMac's job.
public struct LayoutEngine: Sendable {
    /// Frame each window had before Pavé placed it (for `restore`): the last
    /// frame seen while the window was *not* at a Pavé placement.
    public private(set) var restoreFrames: [WindowID: Rect] = [:]
    /// Last placement Pavé gave each window, with its target: recognises a
    /// window that refused the exact size and was centered in the target.
    private var placed: [WindowID: (placement: Placement, target: Rect)] = [:]
    /// Floating frame of a window being dragged (becomes its restore frame on drop).
    private var dragStartFrames: [WindowID: Rect] = [:]
    /// Frame Pavé gave each window dropped in zones.
    private var zoneTargets: [WindowID: Rect] = [:]
    /// Where a window that refused its zone's size ended up (kept on screen).
    private var zoneSettled: [WindowID: Rect] = [:]

    public init() {}

    /// Single-screen convenience (tests).
    public mutating func handle(_ command: LayoutCommand, window: WindowSnapshot, screen: Screen) -> LayoutAction {
        handle(command, window: window, screens: [screen])
    }

    /// `zones`: the layout of a screen, nil for halves and quarters.
    public mutating func handle(
        _ command: LayoutCommand, window: WindowSnapshot, screens: [Screen],
        zones: (Screen) -> ScreenZones? = { _ in nil }
    ) -> LayoutAction {
        guard window.state == .normal else { return .none(reason: "window is \(window.state.rawValue)") }
        guard let screen = Self.screen(for: window.frame, among: screens) else { return .none(reason: "no screen") }
        if let layout = zones(screen),
            let action = handleInZones(command, window: window, screen: screen, layout, screens, zones)
        {
            return action
        }
        let current = placement(of: window, on: screen)
        // A window off any placement is "floating": its frame is the one to restore.
        if current == nil { restoreFrames[window.id] = window.frame }

        switch command {
        case .snapLeft, .snapRight:
            let toLeft = command == .snapLeft
            let side: Placement = toLeft ? .left : .right
            switch current {
            case let p? where toLeft ? p.isLeftSide : p.isRightSide:
                // Already against that edge: continue on the neighbour screen, other side.
                guard let next = Self.neighbour(of: screen, toLeft: toLeft, among: screens) else {
                    return .none(reason: "already \(p.rawValue), no screen on the \(toLeft ? "left" : "right")")
                }
                if let layout = zones(next) {
                    return enterZones(window, from: toLeft ? .trailing : .leading, of: next, layout)
                }
                return place(window, p.mirrored, on: next)
            case let p? where p != .maximized:
                // On the other side: quarters slide across, halves go back to floating.
                if p == .left || p == .right { return restoreOrMinimize(window, fallback: side, on: screen, screens) }
                return place(window, p.mirrored, on: screen)
            default:
                return place(window, side, on: screen)
            }

        case .maximize:
            switch current {
            case .left?: return place(window, .topLeft, on: screen)
            case .right?: return place(window, .topRight, on: screen)
            case .bottomLeft?: return place(window, .left, on: screen)
            case .bottomRight?: return place(window, .right, on: screen)
            case .maximized?: return .none(reason: "already maximized")
            default: return place(window, .maximized, on: screen)
            }

        case .restore:
            switch current {
            case .left?: return place(window, .bottomLeft, on: screen)
            case .right?: return place(window, .bottomRight, on: screen)
            case .topLeft?: return place(window, .left, on: screen)
            case .topRight?: return place(window, .right, on: screen)
            case .maximized?: return restoreOrMinimize(window, fallback: nil, on: screen, screens)
            default:
                placed[window.id] = nil
                return .minimize
            }

        case .moveToScreenLeft, .moveToScreenRight:
            let toLeft = command == .moveToScreenLeft
            guard let next = Self.neighbour(of: screen, toLeft: toLeft, among: screens) else {
                return .none(reason: "no screen on the \(toLeft ? "left" : "right")")
            }
            if let current { return place(window, current, on: next) }
            return .setFrame(Self.carry(window.frame, from: screen.visibleFrame, to: next.visibleFrame))
        }
    }

    // MARK: - Zones

    /// The zones' frame a window was put at, if it is still there: exactly,
    /// centered (the app refused the size), or where it settled on screen.
    public func zoneTarget(of window: WindowSnapshot) -> Rect? {
        guard let target = zoneTargets[window.id] else { return nil }
        let f = window.frame
        if f.isClose(to: target) || f.isClose(to: Self.centered(width: f.width, height: f.height, in: target)) {
            return target
        }
        if let settled = zoneSettled[window.id], f.isClose(to: settled) { return target }
        return nil
    }

    /// The window refused its zone's size and ended at `frame` (Commander).
    public mutating func settled(_ id: WindowID, at frame: Rect) {
        guard zoneTargets[id] != nil else { return }
        zoneSettled[id] = frame
    }

    /// `frame` moved into `area` when it fits; else against its left edge.
    public static func keptOnScreen(_ frame: Rect, in area: Rect) -> Rect {
        func fit(_ origin: Double, _ size: Double, _ lo: Double, _ hi: Double) -> Double {
            size >= hi - lo ? lo : min(max(origin, lo), hi - size)
        }
        return Rect(
            x: fit(frame.x, frame.width, area.x, area.maxX), y: fit(frame.y, frame.height, area.y, area.maxY),
            width: frame.width, height: frame.height)
    }

    private mutating func setZoneTarget(_ id: WindowID, _ target: Rect?) {
        zoneTargets[id] = target
        zoneSettled[id] = nil
    }

    /// The arrows on a screen that has a layout (Z-a: zones replace halves
    /// and quarters). Nil: the usual handling applies (move to a screen
    /// with a floating window).
    private mutating func handleInZones(
        _ command: LayoutCommand, window: WindowSnapshot, screen: Screen, _ layout: ScreenZones, _ screens: [Screen],
        _ zones: (Screen) -> ScreenZones?
    ) -> LayoutAction? {
        let area = screen.visibleFrame
        // A window that refused its zone's size is still in that zone.
        let reference = zoneTarget(of: window) ?? window.frame
        let current = layout.layout.zones(matching: reference, in: area, gaps: layout.gaps)
        let maximized = window.frame.isClose(to: area)
        // A window in no zone is floating: its frame is the one to restore.
        if current == nil, !maximized { restoreFrames[window.id] = window.frame }

        switch command {
        case .snapLeft, .snapRight:
            let forward = command == .snapRight
            if let next = layout.layout.step(from: reference, forward: forward, in: area, gaps: layout.gaps) {
                return placeInZones(window, layout.layout.frame(of: [next], in: area, gaps: layout.gaps))
            }
            // Past the first or last zone: the neighbour screen.
            guard let next = Self.neighbour(of: screen, toLeft: !forward, among: screens) else {
                return .none(reason: "last zone, no screen on the \(forward ? "right" : "left")")
            }
            if let other = zones(next) {
                return enterZones(window, from: forward ? .leading : .trailing, of: next, other)
            }
            return place(window, forward ? .left : .right, on: next)

        case .maximize:
            return maximized ? .none(reason: "already maximized") : place(window, .maximized, on: screen)

        case .restore:
            if current != nil || maximized { return restoreOrMinimize(window, fallback: nil, on: screen, screens) }
            placed[window.id] = nil
            setZoneTarget(window.id, nil)
            return .minimize

        case .moveToScreenLeft, .moveToScreenRight:
            guard let current,
                let next = Self.neighbour(of: screen, toLeft: command == .moveToScreenLeft, among: screens)
            else { return nil }
            if let other = zones(next) {
                // Same zone numbers there, else its last zone (as when switching layouts).
                let kept = Array(Set(current.map { min($0, other.layout.zones.count - 1) })).sorted()
                return placeInZones(window, other.layout.frame(of: kept, in: next.visibleFrame, gaps: other.gaps))
            }
            setZoneTarget(window.id, nil)
            return .setFrame(Self.carry(window.frame, from: area, to: next.visibleFrame))
        }
    }

    private enum Side { case leading, trailing }

    /// Arriving on a screen with a layout from a neighbour: its first zone
    /// from the left, its last from the right.
    private mutating func enterZones(
        _ window: WindowSnapshot, from side: Side, of screen: Screen, _ layout: ScreenZones
    ) -> LayoutAction {
        let index = side == .leading ? 0 : layout.layout.zones.count - 1
        return placeInZones(window, layout.layout.frame(of: [index], in: screen.visibleFrame, gaps: layout.gaps))
    }

    /// The screen switched layouts (⌃⇧Z): where a window in zones of `old`
    /// goes in `new`, same zone numbers when they exist. Nil: it stays.
    public mutating func reflow(_ window: WindowSnapshot, from old: ScreenZones, to new: ScreenZones, on screen: Screen)
        -> LayoutAction?
    {
        let reference = zoneTarget(of: window) ?? window.frame
        let area = screen.visibleFrame
        // Matched with the old gaps, placed with the new ones (the editor may change them).
        guard let indices = old.layout.zones(matching: reference, in: area, gaps: old.gaps) else { return nil }
        let kept = Array(Set(indices.map { min($0, new.layout.zones.count - 1) })).sorted()
        let target = new.layout.frame(of: kept, in: area, gaps: new.gaps)
        guard !target.isClose(to: reference) else { return nil }
        return placeInZones(window, target)
    }

    /// A window goes into zone `index` (app rule `zone = N` for a new one,
    /// the zone picker): its floating frame is remembered, so dragging it out
    /// gives its size back. One already in zones keeps the frame from before.
    public mutating func place(_ window: WindowSnapshot, inZone index: Int, of zones: ScreenZones, on screen: Screen)
        -> LayoutAction?
    {
        guard window.state == .normal, zones.layout.zones.indices.contains(index) else { return nil }
        let target = zones.layout.frame(of: [index], in: screen.visibleFrame, gaps: zones.gaps)
        guard !window.frame.isClose(to: target) else { return nil }
        if zoneTargets[window.id] == nil || restoreFrames[window.id] == nil { restoreFrames[window.id] = window.frame }
        return placeInZones(window, target)
    }

    /// Back into its zones on a screen that came back (Z3): the floating
    /// frame from before stays the one to restore.
    public mutating func returnToZones(_ window: WindowSnapshot, _ target: Rect) -> LayoutAction? {
        guard window.state == .normal, !window.frame.isClose(to: target) else { return nil }
        return placeInZones(window, target)
    }

    private mutating func placeInZones(_ window: WindowSnapshot, _ target: Rect) -> LayoutAction {
        placed[window.id] = nil
        setZoneTarget(window.id, target)
        return .setFrame(target)
    }

    // MARK: - Drags

    /// The window was dropped in a zone: same bookkeeping as a hotkey
    /// placement (its floating frame is remembered for `restore`).
    public mutating func drop(_ window: WindowSnapshot, at placement: Placement, on screen: Screen, screens: [Screen])
        -> LayoutAction
    {
        guard window.state == .normal else { return .none(reason: "window is \(window.state.rawValue)") }
        if let origin = Self.screen(for: window.frame, among: screens), self.placement(of: window, on: origin) != nil {
            // Already placed: keep the floating frame from before.
        } else if let floating = dragStartFrames[window.id] {
            restoreFrames[window.id] = floating
        }
        dragStartFrames[window.id] = nil
        setZoneTarget(window.id, nil)
        return place(window, placement, on: screen)
    }

    /// The window was dropped in zones: its floating frame is remembered,
    /// as for a placement, so dragging it out gives its size back.
    public mutating func drop(_ window: WindowSnapshot, inZones target: Rect, screens: [Screen]) -> LayoutAction {
        guard window.state == .normal else { return .none(reason: "window is \(window.state.rawValue)") }
        if !isPlaced(window, screens: screens), let floating = dragStartFrames[window.id] {
            restoreFrames[window.id] = floating
        }
        dragStartFrames[window.id] = nil
        placed[window.id] = nil
        setZoneTarget(window.id, target)
        return .setFrame(target)
    }

    /// At a placement, or still in the zones it was dropped in (exactly, or
    /// centered there when the app refused the size).
    private func isPlaced(_ window: WindowSnapshot, screens: [Screen]) -> Bool {
        if zoneTarget(of: window) != nil { return true }
        guard let screen = Self.screen(for: window.frame, among: screens) else { return false }
        return placement(of: window, on: screen) != nil
    }

    /// A drag starts: if the window is at a Pavé placement and its floating
    /// frame is known, the frame to give it back, positioned so
    /// the cursor keeps the same relative spot along the title bar. Remembers
    /// the floating frame of a window that was not placed.
    public mutating func dragStarted(_ window: WindowSnapshot, cursorX: Double, cursorY: Double, screens: [Screen])
        -> Rect?
    {
        guard isPlaced(window, screens: screens), let floating = restoreFrames[window.id] else {
            dragStartFrames[window.id] = window.frame
            return nil
        }
        placed[window.id] = nil
        setZoneTarget(window.id, nil)
        restoreFrames[window.id] = nil
        let frame = window.frame
        let ratio = frame.width > 0 ? max(0, min(1, (cursorX - frame.x) / frame.width)) : 0.5
        var x = (cursorX - ratio * floating.width).rounded()
        // Kept on the screen it is dragged from (a wide window leaving a corner
        // zone would spill onto the next screen).
        if let area = Self.screen(for: frame, among: screens)?.visibleFrame, floating.width <= area.width {
            x = min(max(x, area.x), area.maxX - floating.width)
        }
        let restored = Rect(x: x, y: frame.y, width: floating.width, height: floating.height)
        dragStartFrames[window.id] = restored
        return restored
    }

    /// The placement the window is at on `screen`, if any (exact frame, or
    /// centered in the target Pavé gave it when the app refused the size).
    public func placement(of window: WindowSnapshot, on screen: Screen) -> Placement? {
        if let exact = Placement.allCases.first(where: { window.frame.isClose(to: $0.frame(in: screen.visibleFrame)) })
        {
            return exact
        }
        if let last = placed[window.id], last.target == last.placement.frame(in: screen.visibleFrame),
            window.frame.isClose(
                to: Self.centered(width: window.frame.width, height: window.frame.height, in: last.target))
        {
            return last.placement
        }
        return nil
    }

    private mutating func place(_ window: WindowSnapshot, _ placement: Placement, on screen: Screen) -> LayoutAction {
        let target = placement.frame(in: screen.visibleFrame)
        placed[window.id] = (placement, target)
        return .setFrame(target)
    }

    /// Back to the frame before Pavé placed the window, if it is known;
    /// otherwise `fallback`, or minimize.
    /// The frame is brought onto the window's current screen if it was taken on
    /// another one (Windows restores on the current screen).
    private mutating func restoreOrMinimize(
        _ window: WindowSnapshot, fallback: Placement?, on screen: Screen, _ screens: [Screen]
    ) -> LayoutAction {
        setZoneTarget(window.id, nil)
        if let frame = restoreFrames.removeValue(forKey: window.id) {
            placed[window.id] = nil
            if let origin = Self.screen(for: frame, among: screens), origin != screen {
                return .setFrame(Self.carry(frame, from: origin.visibleFrame, to: screen.visibleFrame))
            }
            return .setFrame(frame)
        }
        if let fallback { return place(window, fallback, on: screen) }
        placed[window.id] = nil
        return .minimize
    }

    /// The window is gone: drop what we remembered about it.
    public mutating func forget(_ id: WindowID) {
        restoreFrames[id] = nil
        placed[id] = nil
        dragStartFrames[id] = nil
        setZoneTarget(id, nil)
    }

    /// Target frame of a placement command inside `area`.
    public static func target(_ command: LayoutCommand, in area: Rect) -> Rect {
        switch command {
        case .snapLeft: Placement.left.frame(in: area)
        case .snapRight: Placement.right.frame(in: area)
        default: area
        }
    }

    /// The screen showing most of `frame` (or holding its top-left corner if off screen).
    public static func screen(for frame: Rect, among screens: [Screen]) -> Screen? {
        let best = screens.max { $0.frame.intersectionArea(with: frame) < $1.frame.intersectionArea(with: frame) }
        if let best, best.frame.intersectionArea(with: frame) > 0 { return best }
        return screens.first { $0.frame.contains(x: frame.x, y: frame.y) } ?? screens.first
    }

    /// The nearest screen whose centre is to the left (right) of `screen`'s,
    /// preferring one that overlaps it vertically. A screen stacked exactly
    /// above or below is not a left/right neighbour.
    public static func neighbour(of screen: Screen, toLeft: Bool, among screens: [Screen]) -> Screen? {
        let mid = screen.frame.x + screen.frame.width / 2
        let candidates = screens.filter { other in
            let otherMid = other.frame.x + other.frame.width / 2
            return toLeft ? otherMid < mid - 1 : otherMid > mid + 1
        }
        func overlapsVertically(_ other: Screen) -> Bool {
            min(other.frame.maxY, screen.frame.maxY) > max(other.frame.y, screen.frame.y)
        }
        func distance(_ other: Screen) -> Double { abs(other.frame.x + other.frame.width / 2 - mid) }
        return candidates.min { a, b in
            let (oa, ob) = (overlapsVertically(a), overlapsVertically(b))
            return oa != ob ? oa : distance(a) < distance(b)
        }
    }

    /// `frame` moved from one area to another at the same relative position,
    /// shrunk if it does not fit (Win+Shift+arrow on a floating window).
    public static func carry(_ frame: Rect, from source: Rect, to target: Rect) -> Rect {
        let width = min(frame.width, target.width)
        let height = min(frame.height, target.height)
        func relative(_ offset: Double, _ free: Double) -> Double { free > 0 ? max(0, min(1, offset / free)) : 0 }
        let rx = relative(frame.x - source.x, source.width - frame.width)
        let ry = relative(frame.y - source.y, source.height - frame.height)
        return Rect(
            x: (target.x + rx * (target.width - width)).rounded(),
            y: (target.y + ry * (target.height - height)).rounded(),
            width: width, height: height)
    }

    /// A window that refuses the target size (min/max constraints) is centered
    /// in the target instead (not counted as a failure).
    public static func centered(width: Double, height: Double, in target: Rect) -> Rect {
        Rect(
            x: (target.x + (target.width - width) / 2).rounded(),
            y: (target.y + (target.height - height) / 2).rounded(),
            width: width, height: height)
    }
}

/// Outcome of applying a frame to a real window, measured on its AX thread.
public struct MoveResult: Codable, Sendable, Equatable {
    public var window: UInt32
    public var target: Rect
    /// Frame read back after the move.
    public var actual: Rect?
    /// The app refused the target size; the window was centered in the target.
    public var constrained: Bool
    public var durationMs: Double
    public var error: String?

    public init(window: UInt32, target: Rect, actual: Rect?, constrained: Bool, durationMs: Double, error: String?) {
        self.window = window
        self.target = target
        self.actual = actual
        self.constrained = constrained
        self.durationMs = durationMs
        self.error = error
    }

    /// The window ended where intended (±2 pt), or centered if constrained.
    public var ok: Bool {
        guard error == nil, let actual else { return false }
        if constrained {
            return actual.isClose(
                to: LayoutEngine.centered(width: actual.width, height: actual.height, in: target))
        }
        return actual.isClose(to: target)
    }
}
