/// Platform-independent rectangle in global screen coordinates
/// (top-left origin, as used by the Accessibility API).
public struct Rect: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { max(0, width) * max(0, height) }

    /// Overlapping area with `other` (0 when disjoint).
    public func intersectionArea(with other: Rect) -> Double {
        let w = min(maxX, other.maxX) - max(x, other.x)
        let h = min(maxY, other.maxY) - max(y, other.y)
        return w > 0 && h > 0 ? w * h : 0
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    /// True when every edge is within `tolerance` points of `other`.
    public func isClose(to other: Rect, tolerance: Double = 2) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    public var description: String {
        "(\(Int(x)), \(Int(y)), \(Int(width))×\(Int(height)))"
    }
}
