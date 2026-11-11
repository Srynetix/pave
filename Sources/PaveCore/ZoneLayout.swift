/// A layout of zones on one screen, FancyZones style: windows dragged or moved
/// with the keyboard go into one zone, or span several. Pure.
///
/// Zones are written in **percent** of the screen's usable area (integers: the
/// TOML subset has no floats), and numbered in reading order of their columns:
/// by left edge, then by top edge. They may leave holes but never overlap.
public struct ZoneLayout: Equatable, Sendable {
    public struct Zone: Equatable, Hashable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
        public var maxX: Int { x + width }
        public var maxY: Int { y + height }
    }

    /// Config name: a built-in ("focus") or a `[layouts."<name>"]` table.
    public var name: String
    /// Sorted by left edge, then top edge (zone 1 is `zones[0]`).
    public private(set) var zones: [Zone]

    public static let maxZones = 16

    public struct Invalid: Error, Equatable, Sendable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    public init(name: String, zones: [Zone]) throws(Invalid) {
        guard !zones.isEmpty, zones.count <= Self.maxZones else {
            throw Invalid(message: "a layout needs 1 to \(Self.maxZones) zones, not \(zones.count)")
        }
        for (i, z) in zones.enumerated() {
            guard z.x >= 0, z.y >= 0, z.width > 0, z.height > 0, z.maxX <= 100, z.maxY <= 100 else {
                throw Invalid(
                    message: "zone \(i + 1) [\(z.x), \(z.y), \(z.width), \(z.height)] must stay within 0 to 100 %")
            }
            for (j, other) in zones.enumerated().prefix(i) where Self.overlap(z, other) {
                throw Invalid(message: "zones \(j + 1) and \(i + 1) overlap")
            }
        }
        self.name = name
        self.zones = zones.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }

    private static func overlap(_ a: Zone, _ b: Zone) -> Bool {
        a.x < b.maxX && b.x < a.maxX && a.y < b.maxY && b.y < a.maxY
    }

    // MARK: Built-in layouts

    public static let builtIn: [ZoneLayout] = [
        try! ZoneLayout(
            name: "focus",
            zones: [.init(0, 0, 25, 100), .init(25, 0, 50, 100), .init(75, 0, 25, 50), .init(75, 50, 25, 50)]),
        try! ZoneLayout(name: "thirds", zones: [.init(0, 0, 33, 100), .init(33, 0, 34, 100), .init(67, 0, 33, 100)]),
        try! ZoneLayout(
            name: "main-and-stack", zones: [.init(0, 0, 60, 100), .init(60, 0, 40, 50), .init(60, 50, 40, 50)]),
        try! ZoneLayout(name: "halves", zones: [.init(0, 0, 50, 100), .init(50, 0, 50, 100)]),
        try! ZoneLayout(
            name: "grid",
            zones: [
                .init(0, 0, 33, 50), .init(33, 0, 34, 50), .init(67, 0, 33, 50),
                .init(0, 50, 33, 50), .init(33, 50, 34, 50), .init(67, 50, 33, 50),
            ]),
    ]

    // MARK: Geometry

    /// The zones without gaps, on integral points: neighbours share their edge exactly.
    public func cells(in area: Rect) -> [Rect] {
        func ex(_ p: Int) -> Double { area.x + (area.width * Double(p) / 100).rounded() }
        func ey(_ p: Int) -> Double { area.y + (area.height * Double(p) / 100).rounded() }
        return zones.map { z in
            Rect(x: ex(z.x), y: ey(z.y), width: ex(z.maxX) - ex(z.x), height: ey(z.maxY) - ey(z.y))
        }
    }

    /// Where windows go: `gaps` points along the screen edges and between zones.
    public func frames(in area: Rect, gaps: Double = 0) -> [Rect] {
        zip(zones, cells(in: area)).map { z, cell in Self.inset(cell, z, gaps) }
    }

    /// An edge on the screen's border gets the whole gap; an inner one, half
    /// (the larger half on its leading side), so two neighbours are `gaps` apart.
    private static func inset(_ cell: Rect, _ z: Zone, _ gaps: Double) -> Rect {
        let lead = gaps - (gaps / 2).rounded(.down)
        let trail = (gaps / 2).rounded(.down)
        let left = z.x == 0 ? gaps : trail
        let right = z.maxX == 100 ? gaps : lead
        let top = z.y == 0 ? gaps : trail
        let bottom = z.maxY == 100 ? gaps : lead
        return Rect(
            x: cell.x + left, y: cell.y + top,
            width: max(1, cell.width - left - right), height: max(1, cell.height - top - bottom))
    }

    /// The zone under a point: the one containing it, else the nearest (holes, or off the area).
    public func zone(atX x: Double, y: Double, in area: Rect) -> Int {
        let cells = cells(in: area)
        if let hit = cells.firstIndex(where: { $0.contains(x: x, y: y) }) { return hit }
        return cells.indices.min { Self.distance(x, y, cells[$0]) < Self.distance(x, y, cells[$1]) }!
    }

    /// Zones from `a` to `b` (⇧ while dragging): every zone inside the box
    /// that encloses both, and the frame covering them.
    public func span(_ a: Int, _ b: Int, in area: Rect, gaps: Double = 0) -> (zones: [Int], frame: Rect) {
        let cells = cells(in: area)
        let box = Self.union(cells[a], cells[b])
        let covered = cells.indices.filter { box.intersectionArea(with: cells[$0]) >= cells[$0].area * 0.5 }
        return (covered, frame(of: covered, in: area, gaps: gaps))
    }

    /// The frame enclosing several zones, with the gaps of the outer ones.
    public func frame(of indices: [Int], in area: Rect, gaps: Double = 0) -> Rect {
        let frames = frames(in: area, gaps: gaps)
        return indices.dropFirst().reduce(frames[indices[0]]) { Self.union($0, frames[$1]) }
    }

    /// The zones a window fills exactly, one or a span (Z-e: deduced from its
    /// frame, nothing is stored). Nil for a window placed elsewhere.
    public func zones(matching frame: Rect, in area: Rect, gaps: Double = 0, tolerance: Double = 3) -> [Int]? {
        let frames = frames(in: area, gaps: gaps)
        if let one = frames.firstIndex(where: { $0.isClose(to: frame, tolerance: tolerance) }) { return [one] }
        let inside = frames.indices.filter { i in
            frames[i].x >= frame.x - tolerance && frames[i].maxX <= frame.maxX + tolerance
                && frames[i].y >= frame.y - tolerance && frames[i].maxY <= frame.maxY + tolerance
        }
        guard inside.count > 1, self.frame(of: inside, in: area, gaps: gaps).isClose(to: frame, tolerance: tolerance)
        else {
            return nil
        }
        return inside
    }

    /// ⌃← / ⌃→: the zone before or after the window's, in zone order. A span
    /// steps from its first or last zone; a window in no zone goes to the zone
    /// under its centre. Nil past the first or last zone: the caller moves on
    /// to the next screen.
    public func step(from frame: Rect, forward: Bool, in area: Rect, gaps: Double = 0) -> Int? {
        guard let current = zones(matching: frame, in: area, gaps: gaps) else {
            return zone(atX: frame.x + frame.width / 2, y: frame.y + frame.height / 2, in: area)
        }
        let next = forward ? current.max()! + 1 : current.min()! - 1
        return zones.indices.contains(next) ? next : nil
    }

    /// Where a window filling zones of `old` goes when the screen switches to
    /// this layout: the same zone numbers when they exist, else the last zone.
    /// Nil for a window in no zone of `old` (it stays where it is).
    public func reflow(_ frame: Rect, from old: ZoneLayout, in area: Rect, gaps: Double = 0) -> Rect? {
        guard let indices = old.zones(matching: frame, in: area, gaps: gaps) else { return nil }
        let kept = Array(Set(indices.map { min($0, zones.count - 1) })).sorted()
        return self.frame(of: kept, in: area, gaps: gaps)
    }

    private static func union(_ a: Rect, _ b: Rect) -> Rect {
        let x = min(a.x, b.x)
        let y = min(a.y, b.y)
        return Rect(x: x, y: y, width: max(a.maxX, b.maxX) - x, height: max(a.maxY, b.maxY) - y)
    }

    private static func distance(_ x: Double, _ y: Double, _ r: Rect) -> Double {
        let dx = max(r.x - x, 0, x - r.maxX)
        let dy = max(r.y - y, 0, y - r.maxY)
        return dx * dx + dy * dy
    }
}

/// A screen's layout as the app resolves it (workspace shown, tiling
/// ignored), with the settings that go with it.
public struct ScreenZones: Equatable, Sendable {
    public var layout: ZoneLayout
    public var gaps: Double
    /// Zones show while dragging only with ctrl held (`show = "ctrl"`).
    public var needsControl: Bool
    public init(layout: ZoneLayout, gaps: Double, needsControl: Bool = false) {
        self.layout = layout
        self.gaps = gaps
        self.needsControl = needsControl
    }
}

/// `[zones]` and `[layouts."<name>"]` of the config file.
public struct ZoneSettings: Equatable, Sendable {
    /// Off by default: halves and quarters everywhere, as before.
    public var enabled = false
    /// Points along the screen edges and between zones.
    public var gaps = 8
    /// When zones show while dragging: always, or only while ctrl is held.
    public var show: Show = .always
    /// ⌃← / ⌃→ move between zones on a screen with a layout (else: halves).
    public var keyboard = true
    /// Screen ("builtin", part of its name, or its UUID) → layout name, or "none".
    public var screens: [String: String] = [:]
    /// Workspace number → layout name, on the screens that have a layout.
    public var workspaces: [Int: String] = [:]
    /// The user's layouts, by name.
    public var layouts: [String: ZoneLayout] = [:]

    public enum Show: String, Sendable, CaseIterable {
        case always, ctrl
    }

    public init() {}

    public static let none = "none"

    /// The user's layout first, so a built-in name can be redefined.
    public func layout(named name: String) -> ZoneLayout? {
        layouts[name] ?? ZoneLayout.builtIn.first { $0.name == name }
    }

    /// The layout of a screen showing `workspace`, or nil (halves and quarters).
    /// Screen keys, most precise first: its UUID, "builtin", then part of its name.
    public func layout(screenID: String, screenName: String, isBuiltIn: Bool, workspace: Int? = nil) -> ZoneLayout? {
        guard enabled, let key = screenKey(screenID: screenID, screenName: screenName, isBuiltIn: isBuiltIn),
            let name = screens[key], name != Self.none
        else { return nil }
        if let workspace, let override = workspaces[workspace] {
            return override == Self.none ? nil : layout(named: override)
        }
        return layout(named: name)
    }

    /// The `[zones.screens]` key naming a screen, if one does.
    public func screenKey(screenID: String, screenName: String, isBuiltIn: Bool) -> String? {
        let keys = screens.keys.sorted()
        let id = screenID.lowercased()
        let name = screenName.lowercased()
        let builtIn: (String) -> Bool = { ["builtin", "built-in"].contains($0.lowercased()) }
        return keys.first { !id.isEmpty && $0.lowercased() == id }
            ?? (isBuiltIn ? keys.first(where: builtIn) : nil)
            ?? keys.first { !builtIn($0) && !$0.isEmpty && name.contains($0.lowercased()) }
    }

    /// The key to write for a screen no key names yet: "builtin", else the
    /// first word of its name made of letters and digits ("LG"), else its UUID.
    public static func newScreenKey(screenID: String, screenName: String, isBuiltIn: Bool) -> String {
        if isBuiltIn { return "builtin" }
        let word = screenName.split(separator: " ").first.map { String($0.filter { $0.isLetter || $0.isNumber }) } ?? ""
        return word.isEmpty ? screenID : word
    }

    /// The ⌃⇧Z picker: built-in layouts, then the user's (sorted), then "none".
    public var choices: [String] {
        let builtIn = ZoneLayout.builtIn.map(\.name)
        return builtIn + layouts.keys.filter { !builtIn.contains($0) }.sorted() + [Self.none]
    }
}
