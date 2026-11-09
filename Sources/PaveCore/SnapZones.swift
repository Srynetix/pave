/// Where a window dragged with the cursor at a point would snap. Pure: driven
/// by the cursor only — the AX frame lags ~150 ms behind a drag and is never
/// used here.
///
/// Zones sit against the screen's **frame** edges (where the cursor stops),
/// and give a placement inside its **visible** area:
/// - left / right edge: half; near its ends, the quarter;
/// - top edge: maximized; near its ends, the top quarters;
/// - bottom edge: only its ends (bottom quarters), as Windows.
/// Hysteresis: a zone is entered within `enter` points of the edge and kept
/// until the cursor is `exit` points away, so it does not flicker.
public struct SnapZones: Sendable {
    public struct Zone: Equatable, Sendable {
        public var placement: Placement
        public var screen: Screen
        public var frame: Rect { placement.frame(in: screen.visibleFrame) }
    }

    public var enter: Double = 6
    public var exit: Double = 40
    /// Length along an edge, from a corner, that gives a quarter.
    public var corner: Double = 90

    public init() {}

    public func zone(atX x: Double, y: Double, screens: [Screen], current: Zone?) -> Zone? {
        // Keep the current zone while the cursor stays near its edge.
        if let current, let kept = zone(x: x, y: y, on: current.screen, margin: exit),
            kept.placement == current.placement || sameEdge(kept.placement, current.placement)
        {
            return kept
        }
        guard let screen = screens.first(where: { $0.frame.contains(x: x, y: y) })
            ?? screens.min(by: { distance(x, y, $0.frame) < distance(x, y, $1.frame) })
        else { return nil }
        return zone(x: x, y: y, on: screen, margin: enter)
    }

    private func zone(x: Double, y: Double, on screen: Screen, margin: Double) -> Zone? {
        let f = screen.frame
        let nearLeft = x <= f.x + margin, nearRight = x >= f.maxX - 1 - margin
        let nearTop = y <= f.y + margin, nearBottom = y >= f.maxY - 1 - margin
        let topEnd = y <= f.y + corner, bottomEnd = y >= f.maxY - corner
        let leftEnd = x <= f.x + corner, rightEnd = x >= f.maxX - corner
        // The point must be on (or just off) this screen.
        guard x >= f.x - margin, x <= f.maxX + margin, y >= f.y - margin, y <= f.maxY + margin else { return nil }
        let placement: Placement?
        if nearLeft {
            placement = topEnd ? .topLeft : bottomEnd ? .bottomLeft : .left
        } else if nearRight {
            placement = topEnd ? .topRight : bottomEnd ? .bottomRight : .right
        } else if nearTop {
            placement = leftEnd ? .topLeft : rightEnd ? .topRight : .maximized
        } else if nearBottom {
            placement = leftEnd ? .bottomLeft : rightEnd ? .bottomRight : nil
        } else {
            placement = nil
        }
        return placement.map { Zone(placement: $0, screen: screen) }
    }

    /// Moving along one edge (left half ↔ its quarters) is not leaving it.
    private func sameEdge(_ a: Placement, _ b: Placement) -> Bool {
        (a.isLeftSide && b.isLeftSide) || (a.isRightSide && b.isRightSide)
            || ([a, b].allSatisfy { [.maximized, .topLeft, .topRight].contains($0) })
    }

    private func distance(_ x: Double, _ y: Double, _ r: Rect) -> Double {
        let dx = max(r.x - x, 0, x - r.maxX)
        let dy = max(r.y - y, 0, y - r.maxY)
        return dx * dx + dy * dy
    }
}
