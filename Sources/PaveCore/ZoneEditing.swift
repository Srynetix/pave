/// A layout being edited (Z4): zones in integer percent, changed by the
/// editor's operations, with undo. Pure; the editor window draws it.
///
/// Zones stay sorted like `ZoneLayout` (by left edge, then top edge), so the
/// numbers shown while editing are the ones the layout will have.
public struct ZoneDraft: Equatable, Sendable {
    public private(set) var zones: [ZoneLayout.Zone]
    private var history: [[ZoneLayout.Zone]] = []

    /// Separators snap to this step; ⇧ in the editor uses 1.
    public static let step = 5
    /// No zone narrower or lower than this (percent).
    public static let minSize = 5
    static let maxUndo = 100

    public init(_ layout: ZoneLayout) {
        zones = layout.zones
    }

    public init(zones: [ZoneLayout.Zone]) {
        self.zones = Self.sorted(zones)
    }

    public var canUndo: Bool { !history.isEmpty }

    /// The layout to save (always valid: every operation keeps it so).
    public func layout(named name: String) throws(ZoneLayout.Invalid) -> ZoneLayout {
        try ZoneLayout(name: name, zones: zones)
    }

    /// Starts again from a template (undoable).
    public mutating func replace(with layout: ZoneLayout) {
        guard layout.zones != zones else { return }
        record()
        zones = layout.zones
    }

    public mutating func undo() {
        guard let last = history.popLast() else { return }
        zones = last
    }

    // MARK: Zones

    /// The zone containing a point given in percent, if any (holes: nil).
    public func zone(atX x: Double, y: Double) -> Int? {
        zones.firstIndex { Double($0.x) <= x && x < Double($0.maxX) && Double($0.y) <= y && y < Double($0.maxY) }
    }

    /// Cuts zone `i` in two, side by side (`columns`) or one above the other,
    /// near its middle on the step. Returns the index of the first half, or
    /// nil when the zone is too small to cut.
    public mutating func split(_ i: Int, columns: Bool) -> Int? {
        guard zones.indices.contains(i) else { return nil }
        let z = zones[i]
        let (start, size) = columns ? (z.x, z.width) : (z.y, z.height)
        guard size >= 2 * Self.minSize else { return nil }
        // The middle, on the step when that leaves both halves big enough.
        var cut = start + size / 2
        let snapped = Int((Double(cut) / Double(Self.step)).rounded()) * Self.step
        if snapped - start >= Self.minSize, start + size - snapped >= Self.minSize { cut = snapped }
        let first = columns ? ZoneLayout.Zone(z.x, z.y, cut - z.x, z.height) : ZoneLayout.Zone(z.x, z.y, z.width, cut - z.y)
        let second = columns ? ZoneLayout.Zone(cut, z.y, z.maxX - cut, z.height) : ZoneLayout.Zone(z.x, cut, z.width, z.maxY - cut)
        guard zones.count < ZoneLayout.maxZones else { return nil }
        record()
        zones.remove(at: i)
        zones = Self.sorted(zones + [first, second])
        return zones.firstIndex(of: first)
    }

    /// Merges two zones that together make a rectangle (same height side by
    /// side, or same width one above the other). Returns the merged zone's
    /// index, or nil when they do not.
    public mutating func merge(_ i: Int, _ j: Int) -> Int? {
        guard i != j, zones.indices.contains(i), zones.indices.contains(j) else { return nil }
        let a = zones[i], b = zones[j]
        let x = min(a.x, b.x), y = min(a.y, b.y)
        let merged = ZoneLayout.Zone(x, y, max(a.maxX, b.maxX) - x, max(a.maxY, b.maxY) - y)
        // They do not overlap: the box is theirs alone when its area is the sum of theirs.
        guard merged.width * merged.height == a.width * a.height + b.width * b.height else { return nil }
        record()
        zones = Self.sorted(zones.enumerated().filter { $0.offset != i && $0.offset != j }.map(\.element) + [merged])
        return zones.firstIndex(of: merged)
    }

    /// Removes zone `i`, leaving a hole (the last zone stays).
    @discardableResult
    public mutating func remove(_ i: Int) -> Bool {
        guard zones.count > 1, zones.indices.contains(i) else { return false }
        record()
        zones.remove(at: i)
        return true
    }

    // MARK: Separators

    /// A line between zones that can be dragged: vertical (between columns)
    /// or horizontal, at `position`, from `start` to `end` along it.
    public struct Separator: Equatable, Sendable {
        public var vertical: Bool
        public var position: Int
        public var start: Int, end: Int
        /// Zones ending on the line (left of / above it), and starting on it.
        public var before: [ZoneLayout.Zone], after: [ZoneLayout.Zone]
    }

    /// Every inner edge, cut into the pieces that move together: zones on
    /// either side whose spans along the line touch or overlap.
    public var separators: [Separator] {
        [true, false].flatMap { vertical in
            let positions = Set(zones.flatMap { z in vertical ? [z.x, z.maxX] : [z.y, z.maxY] }).filter { $0 > 0 && $0 < 100 }
            return positions.sorted().flatMap { separators(vertical: vertical, at: $0) }
        }
    }

    private func separators(vertical: Bool, at p: Int) -> [Separator] {
        func span(_ z: ZoneLayout.Zone) -> (Int, Int) { vertical ? (z.y, z.maxY) : (z.x, z.maxX) }
        let before = zones.filter { (vertical ? $0.maxX : $0.maxY) == p }
        let after = zones.filter { (vertical ? $0.x : $0.y) == p }
        var pieces: [Separator] = []
        for (z, isBefore) in (before.map { ($0, true) } + after.map { ($0, false) }).sorted(by: { span($0.0).0 < span($1.0).0 }) {
            let (s, e) = span(z)
            // Spans that overlap move together; ones that only touch (a grid's
            // top and bottom rows) are separate pieces.
            if var last = pieces.last, s < last.end {
                last.end = max(last.end, e)
                if isBefore { last.before.append(z) } else { last.after.append(z) }
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(Separator(vertical: vertical, position: p, start: s, end: e, before: isBefore ? [z] : [], after: isBefore ? [] : [z]))
            }
        }
        return pieces
    }

    /// Where a separator may go: every zone it moves keeps `minSize`, and it
    /// never runs into a zone beyond it.
    public func range(of separator: Separator) -> ClosedRange<Int> {
        let v = separator.vertical
        func lo(_ z: ZoneLayout.Zone) -> Int { v ? z.x : z.y }
        func hi(_ z: ZoneLayout.Zone) -> Int { v ? z.maxX : z.maxY }
        func spanOverlaps(_ z: ZoneLayout.Zone) -> Bool {
            let (s, e) = v ? (z.y, z.maxY) : (z.x, z.maxX)
            return s < separator.end && separator.start < e
        }
        let moved = separator.before + separator.after
        let others = zones.filter { !moved.contains($0) && spanOverlaps($0) }
        var low = separator.before.map { lo($0) + Self.minSize }.max() ?? 0
        var high = separator.after.map { hi($0) - Self.minSize }.min() ?? 100
        low = max(low, others.filter { hi($0) <= separator.position }.map(hi).max() ?? 0)
        high = min(high, others.filter { lo($0) >= separator.position }.map(lo).min() ?? 100)
        return low...max(low, high)
    }

    /// Moves a separator towards `position`, snapped to `step` and kept in
    /// its range. Returns it at its new place (call `record` once per drag:
    /// `beginMove`).
    @discardableResult
    public mutating func move(_ separator: Separator, to position: Int, step: Int = ZoneDraft.step) -> Separator {
        let allowed = range(of: separator)
        let snapped = step > 1 ? Int((Double(position) / Double(step)).rounded()) * step : position
        let p = min(max(snapped, allowed.lowerBound), allowed.upperBound)
        guard p != separator.position else { return separator }
        let v = separator.vertical
        func moved(_ z: ZoneLayout.Zone, before: Bool) -> ZoneLayout.Zone {
            switch (v, before) {
            case (true, true): .init(z.x, z.y, p - z.x, z.height)
            case (true, false): .init(p, z.y, z.maxX - p, z.height)
            case (false, true): .init(z.x, z.y, z.width, p - z.y)
            case (false, false): .init(z.x, p, z.width, z.maxY - p)
            }
        }
        let before = separator.before.map { moved($0, before: true) }
        let after = separator.after.map { moved($0, before: false) }
        let old = separator.before + separator.after
        zones = Self.sorted(zones.filter { !old.contains($0) } + before + after)
        var result = separator
        result.position = p
        result.before = before
        result.after = after
        return result
    }

    /// Before a drag: one undo step for the whole drag.
    public mutating func beginMove() { record() }

    // MARK: -

    private mutating func record() {
        history.append(zones)
        if history.count > Self.maxUndo { history.removeFirst() }
    }

    private static func sorted(_ zones: [ZoneLayout.Zone]) -> [ZoneLayout.Zone] {
        zones.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }
}

extension ZoneLayout {
    /// The `zones = [[x, y, w, h], …]` value of a `[layouts."<name>"]` table.
    public var tomlZones: String {
        "[" + zones.map { "[\($0.x), \($0.y), \($0.width), \($0.height)]" }.joined(separator: ", ") + "]"
    }

    /// A name the config file can hold: letters, digits, spaces, - and _.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name != ZoneSettings.none
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            && name.first != " " && name.last != " "
    }
}
