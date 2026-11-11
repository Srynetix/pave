/// Window magnetism and shared edges. Pure: PaveMac reads the frames (the
/// dragged window's live bounds, the others' AX frames) and applies the result.
///
/// - Magnetism: a window dropped with an edge near another window's edge (or
///   the usable area's) is moved so they touch, or line up.
/// - Shared edges: resizing a window by an edge another window touches
///   resizes that one too, the edge between them stays shared.
public enum Magnet {
    public enum Edge: String, Sendable, CaseIterable {
        case left, right, top, bottom
    }

    /// `frame` moved (never resized) so that, on each axis, the nearest of
    /// its edges within `distance` of a target sits on it. Targets: the
    /// edges of `area`; a window beside it (overlapping its rows): against
    /// it, tops and bottoms aligned; a window above or below it (overlapping
    /// its columns): against it, sides aligned.
    public static func snap(_ frame: Rect, to others: [Rect], area: Rect, distance: Double) -> Rect {
        guard distance > 0 else { return frame }
        func near(_ a: (Double, Double), _ b: (Double, Double)) -> Bool { a.0 < b.1 + distance && b.0 < a.1 + distance }
        let beside = others.filter { near(($0.y, $0.maxY), (frame.y, frame.maxY)) }
        let above = others.filter { near(($0.x, $0.maxX), (frame.x, frame.maxX)) }
        // Moves bringing an edge of the window onto a target: (target − edge).
        var dx = [area.x - frame.x, area.maxX - frame.maxX]
        dx += beside.flatMap { [$0.maxX - frame.x, $0.x - frame.maxX] }  // against it
        dx += above.flatMap { [$0.x - frame.x, $0.maxX - frame.maxX] }  // sides aligned
        var dy = [area.y - frame.y, area.maxY - frame.maxY]
        dy += above.flatMap { [$0.maxY - frame.y, $0.y - frame.maxY] }
        dy += beside.flatMap { [$0.y - frame.y, $0.maxY - frame.maxY] }
        return Rect(
            x: frame.x + smallest(dx, distance), y: frame.y + smallest(dy, distance), width: frame.width,
            height: frame.height)
    }

    private static func smallest(_ moves: [Double], _ distance: Double) -> Double {
        moves.filter { abs($0) <= distance }.min { abs($0) < abs($1) } ?? 0
    }

    /// Stuck against another window (not only the screen's edges): the free
    /// space around `point` it can fill, bounded by the other windows and
    /// `area` (a window on the right 2/3, one dropped against it fills the
    /// first third). Nil when not against a window, when `point` is over
    /// another window, or when the space is smaller than `minSize`.
    public static func fill(
        _ snapped: Rect, point: (x: Double, y: Double), others: [Rect], area: Rect, minSize: Double = 150
    ) -> Rect? {
        func overlap(_ a: (Double, Double), _ b: (Double, Double)) -> Bool { min(a.1, b.1) - max(a.0, b.0) > 1 }
        let against = others.contains { o in
            let rows = overlap((o.y, o.maxY), (snapped.y, snapped.maxY))
            let columns = overlap((o.x, o.maxX), (snapped.x, snapped.maxX))
            return rows && (abs(o.x - snapped.maxX) < 1 || abs(o.maxX - snapped.x) < 1)
                || columns && (abs(o.y - snapped.maxY) < 1 || abs(o.maxY - snapped.y) < 1)
        }
        guard against, !others.contains(where: { $0.contains(x: point.x, y: point.y) }) else { return nil }
        // Across first then up and down, or the other way: the larger one.
        let candidates = [true, false].map { horizontalFirst in
            free(around: point, others: others, area: area, horizontalFirst: horizontalFirst)
        }
        guard let best = candidates.max(by: { $0.area < $1.area }), best.width >= minSize, best.height >= minSize else {
            return nil
        }
        return best
    }

    /// The empty rectangle around `p`: grown along one axis up to the windows
    /// on its line, then along the other up to the windows in that band.
    private static func free(around p: (x: Double, y: Double), others: [Rect], area: Rect, horizontalFirst: Bool)
        -> Rect
    {
        func span(_ value: Double, _ lo: Double, _ hi: Double, _ obstacles: [(Double, Double)]) -> (Double, Double) {
            (
                obstacles.map(\.1).filter { $0 <= value }.reduce(lo, max),
                obstacles.map(\.0).filter { $0 >= value }.reduce(hi, min)
            )
        }
        func crosses(_ a: (Double, Double), _ b: (Double, Double)) -> Bool { min(a.1, b.1) - max(a.0, b.0) > 1 }
        if horizontalFirst {
            let row = others.filter { $0.y <= p.y && p.y <= $0.maxY }
            let (l, r) = span(p.x, area.x, area.maxX, row.map { ($0.x, $0.maxX) })
            let band = others.filter { crosses(($0.x, $0.maxX), (l, r)) }
            let (t, b) = span(p.y, area.y, area.maxY, band.map { ($0.y, $0.maxY) })
            return Rect(x: l, y: t, width: r - l, height: b - t)
        }
        let column = others.filter { $0.x <= p.x && p.x <= $0.maxX }
        let (t, b) = span(p.y, area.y, area.maxY, column.map { ($0.y, $0.maxY) })
        let band = others.filter { crosses(($0.y, $0.maxY), (t, b)) }
        let (l, r) = span(p.x, area.x, area.maxX, band.map { ($0.x, $0.maxX) })
        return Rect(x: l, y: t, width: r - l, height: b - t)
    }

    /// The edges of `start` that moved in `now` (a resize by an edge or a corner).
    public static func movedEdges(from start: Rect, to now: Rect) -> Set<Edge> {
        var edges: Set<Edge> = []
        if abs(now.x - start.x) > 1 { edges.insert(.left) }
        if abs(now.maxX - start.maxX) > 1 { edges.insert(.right) }
        if abs(now.y - start.y) > 1 { edges.insert(.top) }
        if abs(now.maxY - start.maxY) > 1 { edges.insert(.bottom) }
        return edges
    }

    /// A window touching `frame` by one of its edges.
    public struct Neighbour: Equatable, Sendable {
        public var id: WindowID
        /// Its frame when the resize started.
        public var frame: Rect
        /// The edge of the resized window it touches.
        public var edge: Edge
        /// The space between the two edges (a gap between zones), kept.
        public var gap: Double
    }

    /// The windows whose edge faces one of `frame`'s, at most `tolerance`
    /// away (a gap between zones), and that overlap it along that edge.
    public static func neighbours(of frame: Rect, among others: [(WindowID, Rect)], tolerance: Double) -> [Neighbour] {
        func overlap(_ a: (Double, Double), _ b: (Double, Double)) -> Bool { min(a.1, b.1) - max(a.0, b.0) > 20 }
        return others.compactMap { id, other in
            let rows = overlap((other.y, other.maxY), (frame.y, frame.maxY))
            let columns = overlap((other.x, other.maxX), (frame.x, frame.maxX))
            let facing: [(Edge, Double, Bool)] = [
                (.right, other.x - frame.maxX, rows), (.left, frame.x - other.maxX, rows),
                (.bottom, other.y - frame.maxY, columns), (.top, frame.y - other.maxY, columns),
            ]
            guard let (edge, gap, _) = facing.first(where: { $0.2 && $0.1 >= -1 && $0.1 <= tolerance }) else {
                return nil
            }
            return Neighbour(id: id, frame: other, edge: edge, gap: max(0, gap))
        }
    }

    /// The neighbour's frame once the resized window is at `now`: its facing
    /// edge follows, its far edge stays, and it keeps at least `minSize`.
    public static func follow(_ neighbour: Neighbour, resized now: Rect, minSize: Double = 120) -> Rect {
        let f = neighbour.frame
        switch neighbour.edge {
        case .right:
            let x = min(now.maxX + neighbour.gap, f.maxX - minSize)
            return Rect(x: x, y: f.y, width: f.maxX - x, height: f.height)
        case .left:
            return Rect(x: f.x, y: f.y, width: max(minSize, now.x - neighbour.gap - f.x), height: f.height)
        case .bottom:
            let y = min(now.maxY + neighbour.gap, f.maxY - minSize)
            return Rect(x: f.x, y: y, width: f.width, height: f.maxY - y)
        case .top:
            return Rect(x: f.x, y: f.y, width: f.width, height: max(minSize, now.y - neighbour.gap - f.y))
        }
    }
}
