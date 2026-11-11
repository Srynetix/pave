// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// Magnetism (a free drop sticks to the nearby edges) and shared edges (a
/// resize moves the neighbours' facing edge along). ⌥ turns both off.
extension DragSnapController {
    /// How often neighbours follow a resize (an AX move each time).
    static let followInterval: UInt64 = 40_000_000
    /// Space between two windows still counted as a shared edge (zone gaps).
    static let sharedEdgeTolerance: Double = 24

    /// The other windows a dragged or resized one meets: shown, standard, placeable.
    func otherFrames(than id: WindowID) -> [(WindowID, Rect)] {
        registry.store.windows.values.compactMap { window in
            guard window.id != id, window.state == .normal, window.subrole == "AXStandardWindow", isShown(window.id),
                !isTiled(window.id)
            else { return nil }
            return (window.id, window.frame)
        }
    }

    // MARK: Magnetism

    /// While a window is moved with no zone: where the magnet would put it,
    /// shown as the preview (the window follows the cursor until the drop).
    func showMagnet(_ current: inout Press, x: Double, y: Double, screens: [Screen]) {
        guard let id = current.window, let target = magnetTarget(current, x: x, y: y, screens: screens) else {
            if current.magnet != nil { preview.hide() }
            current.magnet = nil
            return
        }
        if current.magnet != target { preview.show(target, below: id) }
        current.magnet = target
    }

    /// The frame under the cursor stuck to the edges near it, nil if it does not move.
    private func magnetTarget(_ current: Press, x: Double, y: Double, screens: [Screen]) -> Rect? {
        guard magnetDistance > 0, !current.option, !current.adopted, let id = current.window, let base = current.base
        else { return nil }
        let frame = Rect(
            x: base.x + (x - current.downX), y: base.y + (y - current.downY), width: base.width, height: base.height)
        return magnet(frame, id: id, cursor: (x, y), screens: screens)?.frame
    }

    /// Where the magnet puts `frame`; `filled`: it takes the free space too
    /// (a size of its own until dragged away, as in a zone).
    private func magnet(_ frame: Rect, id: WindowID, cursor: (x: Double, y: Double), screens: [Screen]) -> (
        frame: Rect, filled: Bool
    )? {
        guard let screen = LayoutEngine.screen(for: frame, among: screens) else { return nil }
        let others = otherFrames(than: id).map(\.1).filter { $0.intersectionArea(with: screen.frame) > 0 }
        let snapped = Magnet.snap(frame, to: others, area: screen.visibleFrame, distance: magnetDistance)
        if magnetFill, let filled = Magnet.fill(snapped, point: cursor, others: others, area: screen.visibleFrame),
            !filled.isClose(to: frame)
        {
            return (filled, true)
        }
        return snapped.isClose(to: frame) ? nil : (snapped, false)
    }

    /// A free drop: the window sticks to the nearby edges. False if nothing to do.
    func magnetDrop(_ done: Press) -> Bool {
        guard magnetDistance > 0, !done.option, let id = done.window, let window = registry.store.windows[id],
            let now = Self.bounds(of: id), let cursor = done.cursor,
            let (target, filled) = magnet(now, id: id, cursor: cursor, screens: Screens.all())
        else { return false }
        var moved = window
        moved.frame = now  // the live bounds: the AX frame lags behind the drag
        let report: @MainActor (MoveResult?) -> Void = { result in
            let verdict = result.map { $0.ok ? "ok" : "MISS" } ?? "skipped"
            Log.info(
                "drag \(id) [\(window.appName)]: magnet\(filled ? " (fills the free space)" : "") \(now) → \(target), \(verdict)"
            )
        }
        // Filled: placed like in a zone, dragging it out gives its size back.
        if filled {
            commander.drop(moved, inZones: target, completion: report)
        } else {
            registry.setFrame(of: moved, to: target, completion: report)
        }
        return true
    }

    // MARK: Shared edges

    /// During a resize: the windows touching the edges that move follow them.
    func followResize(_ current: inout Press, at: UInt64) {
        guard resizeNeighbours, !current.option, let id = current.window, let start = current.startBounds,
            at - current.lastFollowAt >= Self.followInterval
        else { return }
        current.lastFollowAt = at
        if current.neighbours == nil {
            current.neighbours = Magnet.neighbours(
                of: start, among: otherFrames(than: id), tolerance: Self.sharedEdgeTolerance)
        }
        guard let neighbours = current.neighbours, !neighbours.isEmpty, let now = Self.bounds(of: id) else { return }
        follow(neighbours, of: now, from: start)
    }

    private func follow(
        _ neighbours: [Magnet.Neighbour], of now: Rect, from start: Rect, completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let edges = Magnet.movedEdges(from: start, to: now)
        var pending = 0
        var ok = true
        for neighbour in neighbours where edges.contains(neighbour.edge) && !following.contains(neighbour.id) {
            guard let window = registry.store.windows[neighbour.id] else { continue }
            let target = Magnet.follow(neighbour, resized: now)
            guard !target.isClose(to: window.frame) else { continue }
            following.insert(neighbour.id)
            pending += 1
            registry.setFrame(of: window, to: target) { [weak self] result in
                self?.following.remove(neighbour.id)
                ok = ok && result.ok
                pending -= 1
                if pending == 0 { completion?(ok) }
            }
        }
        if pending == 0 { completion?(ok) }
    }

    /// The resize is over: the neighbours take their final place (the last
    /// moves may have been skipped while others were under way).
    func resizeEnded(_ done: Press) {
        guard let id = done.window, let start = done.startBounds, let neighbours = done.neighbours, !neighbours.isEmpty,
            resizeNeighbours, !done.option
        else { return }
        let app = registry.store.windows[id]?.appName ?? "?"
        // The app may still be settling its size: read it a moment later,
        // once the neighbours' moves under way are done.
        func settle(_ attempt: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let now = Self.bounds(of: id) else { return }
                    let edges = Magnet.movedEdges(from: start, to: now)
                    let moved = neighbours.filter { edges.contains($0.edge) }
                    guard !moved.isEmpty else { return }
                    if attempt < 5, moved.contains(where: { self.following.contains($0.id) }) {
                        return settle(attempt + 1)
                    }
                    self.follow(moved, of: now, from: start) { ok in
                        let list = moved.map { "\($0.id) (\($0.edge.rawValue))" }.joined(separator: ", ")
                        Log.info(
                            "resize \(id) [\(app)]: \(moved.count) neighbour(s) followed: \(list), \(ok ? "ok" : "MISS")"
                        )
                    }
                }
            }
        }
        settle(0)
    }
}
