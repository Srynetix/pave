/// Tiling of one workspace, as i3 / AeroSpace: a tree of horizontal and
/// vertical containers, windows as leaves, each child taking a share of its
/// container proportional to its weight.
///
/// Always normalized after a change: no container with a single child, and a
/// container never has the same orientation as its parent (it is merged into
/// it), so nested containers alternate. Pure value: PaveMac applies `frames`.
public enum Direction: String, Sendable, Codable, CaseIterable {
    case left, right, up, down

    var orientation: TilingTree.Orientation { self == .left || self == .right ? .horizontal : .vertical }
    /// Towards the end of a container (right / down).
    var isForward: Bool { self == .right || self == .down }
}

public struct TilingTree: Codable, Equatable, Sendable, CustomStringConvertible {
    /// "H[#1 V[#2 #3]]": window IDs only (for `pave dump` and the logs).
    public var description: String {
        func text(_ node: Node) -> String {
            switch node {
            case .window(let id): id.description
            case .split(let o, let children):
                (o == .horizontal ? "H[" : "V[") + children.map { text($0.node) }.joined(separator: " ") + "]"
            }
        }
        return text(root)
    }

    public enum Orientation: String, Codable, Sendable {
        case horizontal, vertical
        var flipped: Orientation { self == .horizontal ? .vertical : .horizontal }
    }

    public indirect enum Node: Codable, Equatable, Sendable {
        case window(WindowID)
        case split(Orientation, [Child])

        var windows: [WindowID] {
            switch self {
            case .window(let id): [id]
            case .split(_, let children): children.flatMap(\.node.windows)
            }
        }
    }

    public struct Child: Codable, Equatable, Sendable {
        public var node: Node
        public var weight: Double
    }

    /// Always a split (possibly empty).
    public private(set) var root: Node

    /// Root orientation: horizontal on a landscape screen.
    public init(orientation: Orientation = .horizontal) {
        root = .split(orientation, [])
    }

    public var windows: [WindowID] { root.windows }
    public func contains(_ id: WindowID) -> Bool { path(to: id) != nil }
    public var isEmpty: Bool { windows.isEmpty }

    // MARK: - Insert / remove

    /// A new window goes right after `focused`, in the same container, with
    /// the average weight of its siblings; else at the end of the root.
    public mutating func insert(_ id: WindowID, after focused: WindowID? = nil) {
        guard !contains(id) else { return }
        if let focused, let path = path(to: focused), let index = path.last {
            let parent = Array(path.dropLast())
            update(parent) { node in
                guard case .split(let o, var children) = node else { return node }
                children.insert(Child(node: .window(id), weight: Self.averageWeight(children)), at: index + 1)
                return .split(o, children)
            }
        } else {
            update([]) { node in
                guard case .split(let o, var children) = node else { return node }
                children.append(Child(node: .window(id), weight: Self.averageWeight(children)))
                return .split(o, children)
            }
        }
        normalize()
    }

    public mutating func remove(_ id: WindowID) {
        detach(id)
        normalize()
    }

    /// Takes the leaf out without normalizing: every other path stays valid
    /// (a container may be left with one child, or none, until `normalize`).
    private mutating func detach(_ id: WindowID) {
        guard let path = path(to: id), let index = path.last else { return }
        update(Array(path.dropLast())) { node in
            guard case .split(let o, var children) = node else { return node }
            children.remove(at: index)
            return .split(o, children)
        }
    }

    // MARK: - Commands

    public enum MoveResult: Equatable, Sendable {
        case moved
        /// Already against the edge in that direction (Win+arrow then goes to
        /// the neighbour screen, as in the floating mode).
        case atEdge
        case unknownWindow
    }

    /// Win+arrow in a tiled workspace. Next to a sibling in that
    /// direction: swaps with it, or enters it if it is a container. At the edge
    /// of its container: leaves it, next to that container in the nearest
    /// ancestor of the right orientation. At the edge of a root of another
    /// orientation: the root is wrapped so the window takes a side.
    @discardableResult
    public mutating func move(_ id: WindowID, _ direction: Direction) -> MoveResult {
        guard let path = path(to: id) else { return .unknownWindow }
        let axis = direction.orientation
        let step = direction.isForward ? 1 : -1

        // Nearest ancestor of the right orientation where the window's branch
        // has a neighbour in that direction.
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let containerPath = Array(path.prefix(depth))
            guard case .split(let o, let children) = node(at: containerPath), o == axis else { continue }
            let index = path[depth]
            let target = index + step
            if depth == path.count - 1 {
                // The window is a direct child of this container.
                // At the edge of its container: look further up.
                guard children.indices.contains(target) else { continue }
                if case .split = children[target].node {
                    // Enter the neighbour container, on its near side.
                    detach(id)
                    insertInto(
                        neighbourOf: containerPath, from: index, target: target, id: id, forward: direction.isForward)
                } else {
                    update(containerPath) { node in
                        guard case .split(let o, var children) = node else { return node }
                        children.swapAt(index, target)
                        return .split(o, children)
                    }
                }
                normalize()
                return .moved
            }
            // The window is deeper: take it out of its container and put it
            // next to the branch holding it, in this container.
            let weight = Self.averageWeight(children)
            detach(id)  // paths unchanged: the branch is still at `index`
            update(containerPath) { node in
                guard case .split(let o, var children) = node else { return node }
                children.insert(Child(node: .window(id), weight: weight), at: direction.isForward ? index + 1 : index)
                return .split(o, children)
            }
            normalize()
            return .moved
        }

        // No ancestor of that orientation with room: the root.
        guard case .split(let rootOrientation, let children) = root, children.count > 1 else { return .atEdge }
        if rootOrientation == axis { return .atEdge }
        detach(id)
        let rest = Child(node: root, weight: 1)
        let window = Child(node: .window(id), weight: 1)
        root = .split(axis, direction.isForward ? [rest, window] : [window, rest])
        normalize()
        return .moved
    }

    /// Win+Alt+Shift+arrow: right / down grow the window, left / up shrink it,
    /// by `step` of its container (nearest one of that axis), taken from (or
    /// given to) its siblings in proportion. No share goes below `minShare`.
    public mutating func resize(_ id: WindowID, _ direction: Direction, step: Double = 0.05, minShare: Double = 0.1) {
        guard let path = path(to: id) else { return }
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let containerPath = Array(path.prefix(depth))
            guard case .split(let o, let children) = node(at: containerPath), o == direction.orientation,
                children.count > 1
            else { continue }
            let index = path[depth]
            let delta = direction.isForward ? step : -step
            setShare(at: containerPath, index: index, to: share(children, index) + delta, minShare: minShare)
            return
        }
    }

    /// The user resized a tiled window with the mouse: its new
    /// width (height) becomes its share in the nearest container of that axis.
    /// `old` and `new` are the frames before and after, `area` the tiled area.
    public mutating func resized(_ id: WindowID, from old: Rect, to new: Rect, in area: Rect, gaps: Double = 0) {
        guard let path = path(to: id) else { return }
        for axis in [Orientation.horizontal, .vertical] {
            let (oldLength, newLength) = axis == .horizontal ? (old.width, new.width) : (old.height, new.height)
            guard abs(newLength - oldLength) > 1 else { continue }
            for depth in stride(from: path.count - 1, through: 0, by: -1) {
                let containerPath = Array(path.prefix(depth))
                guard case .split(let o, let children) = node(at: containerPath), o == axis, children.count > 1,
                    let containerFrame = frames(in: area, gaps: gaps, containerPath: containerPath)
                else { continue }
                let length =
                    (axis == .horizontal ? containerFrame.width : containerFrame.height)
                    - gaps * Double(children.count - 1)
                guard length > 0 else { break }
                let index = path[depth]
                // The branch grows or shrinks by what the window did.
                let current = share(children, index) * length
                setShare(at: containerPath, index: index, to: (current + newLength - oldLength) / length)
                break
            }
        }
    }

    /// Swaps two windows (drag and drop on another tile).
    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard a != b, let pa = path(to: a), let pb = path(to: b) else { return }
        update(pa) { _ in .window(b) }
        update(pb) { _ in .window(a) }
    }

    /// Flips the orientation of the window's container.
    public mutating func toggleOrientation(of id: WindowID) {
        guard let path = path(to: id) else { return }
        update(Array(path.dropLast())) { node in
            guard case .split(let o, let children) = node else { return node }
            return .split(o.flipped, children)
        }
        normalize()
    }

    // MARK: - Frames

    /// Frame of every window in `area`: `gaps` around the area and between tiles.
    public func frames(in area: Rect, gaps: Double = 0) -> [WindowID: Rect] {
        var result: [WindowID: Rect] = [:]
        Self.layout(root, in: Self.inset(area, gaps), gaps: gaps) { id, rect in result[id] = rect }
        return result
    }

    private func frames(in area: Rect, gaps: Double, containerPath: [Int]) -> Rect? {
        var rect = Self.inset(area, gaps)
        var node = root
        for index in containerPath {
            guard case .split(let o, let children) = node, children.indices.contains(index) else { return nil }
            rect = Self.slices(rect, o, children, gaps)[index]
            node = children[index].node
        }
        return rect
    }

    private static func layout(_ node: Node, in rect: Rect, gaps: Double, _ emit: (WindowID, Rect) -> Void) {
        switch node {
        case .window(let id): emit(id, rect)
        case .split(let o, let children):
            for (child, slice) in zip(children, slices(rect, o, children, gaps)) {
                layout(child.node, in: slice, gaps: gaps, emit)
            }
        }
    }

    /// Splits `rect` along `o` by weight, on whole points; the last slice
    /// takes the rounding remainder so the tiles cover the area exactly.
    private static func slices(_ rect: Rect, _ o: Orientation, _ children: [Child], _ gaps: Double) -> [Rect] {
        guard !children.isEmpty else { return [] }
        let total = children.reduce(0) { $0 + $1.weight }
        let length = (o == .horizontal ? rect.width : rect.height) - gaps * Double(children.count - 1)
        var start = o == .horizontal ? rect.x : rect.y
        let end = start + length + gaps * Double(children.count - 1)
        return children.enumerated().map { i, child in
            let size = i == children.count - 1 ? end - start : (length * child.weight / total).rounded()
            defer { start += size + gaps }
            return o == .horizontal
                ? Rect(x: start, y: rect.y, width: size, height: rect.height)
                : Rect(x: rect.x, y: start, width: rect.width, height: size)
        }
    }

    private static func inset(_ r: Rect, _ d: Double) -> Rect {
        Rect(x: r.x + d, y: r.y + d, width: max(0, r.width - 2 * d), height: max(0, r.height - 2 * d))
    }

    // MARK: - Geometry (focus by direction, also for floating windows)

    /// The window to focus from `id` in `direction` (Win+Alt+arrow): among the
    /// frames entirely on that side, the one overlapping most on the other
    /// axis, then the closest. Works on any set of frames, tiled or not.
    public static func neighbour(of id: WindowID, _ direction: Direction, frames: [WindowID: Rect]) -> WindowID? {
        guard let from = frames[id] else { return nil }
        func overlap(_ r: Rect) -> Double {
            direction.orientation == .horizontal
                ? min(r.maxY, from.maxY) - max(r.y, from.y)
                : min(r.maxX, from.maxX) - max(r.x, from.x)
        }
        func distance(_ r: Rect) -> Double {
            switch direction {
            case .left: from.x - r.maxX
            case .right: r.x - from.maxX
            case .up: from.y - r.maxY
            case .down: r.y - from.maxY
            }
        }
        let candidates = frames.filter { $0.key != id && distance($0.value) > -2 }
        return candidates.min { a, b in
            let (oa, ob) = (overlap(a.value) > 0, overlap(b.value) > 0)
            if oa != ob { return oa }
            let (da, db) = (distance(a.value), distance(b.value))
            return da != db ? da < db : a.key < b.key
        }?.key
    }

    // MARK: - Normalization

    mutating func normalize() {
        root = Self.normalized(root, parent: nil)
        // The root stays a split: a lone window (or nothing) sits in one.
        switch root {
        case .window(let id): root = .split(.horizontal, [Child(node: .window(id), weight: 1)])
        case .split(let o, let children) where children.count == 1:
            if case .split(let inner, let grand) = children[0].node {
                root = .split(inner, grand)
            } else {
                root = .split(o, children)
            }
        default: break
        }
    }

    private static func normalized(_ node: Node, parent: Orientation?) -> Node {
        guard case .split(let o, let children) = node else { return node }
        var flat: [Child] = []
        for child in children {
            let inner = normalized(child.node, parent: o)
            if case .split(let io, let grand) = inner, io == o {
                // Same orientation as us: merge its children, scaled to its weight.
                let total = grand.reduce(0) { $0 + $1.weight }
                flat += grand.map { Child(node: $0.node, weight: child.weight * $0.weight / total) }
            } else if case .split(_, let grand) = inner, grand.isEmpty {
                continue
            } else {
                flat.append(Child(node: inner, weight: child.weight))
            }
        }
        if flat.count == 1, parent != nil { return flat[0].node }
        return .split(o, flat)
    }

    // MARK: - Paths

    /// Indices from the root down to the window.
    func path(to id: WindowID) -> [Int]? {
        func search(_ node: Node, _ path: [Int]) -> [Int]? {
            switch node {
            case .window(let w): return w == id ? path : nil
            case .split(_, let children):
                for (i, child) in children.enumerated() {
                    if let found = search(child.node, path + [i]) { return found }
                }
                return nil
            }
        }
        return search(root, [])
    }

    private func node(at path: [Int]) -> Node? {
        var node = root
        for index in path {
            guard case .split(_, let children) = node, children.indices.contains(index) else { return nil }
            node = children[index].node
        }
        return node
    }

    private mutating func update(_ path: [Int], _ transform: (Node) -> Node) {
        func apply(_ node: Node, _ rest: ArraySlice<Int>) -> Node {
            guard let index = rest.first else { return transform(node) }
            guard case .split(let o, var children) = node, children.indices.contains(index) else { return node }
            children[index].node = apply(children[index].node, rest.dropFirst())
            return .split(o, children)
        }
        root = apply(root, path[...])
    }

    /// Puts `id` into the container that sat at `target` next to `from` in the
    /// container at `containerPath`, on the side facing the window.
    private mutating func insertInto(
        neighbourOf containerPath: [Int], from: Int, target: Int, id: WindowID, forward: Bool
    ) {
        // `detach` took the window out: indices after it shifted down by one.
        let index = target > from ? target - 1 : target
        update(containerPath + [index]) { node in
            guard case .split(let o, var children) = node else { return node }
            children.insert(
                Child(node: .window(id), weight: Self.averageWeight(children)), at: forward ? 0 : children.count)
            return .split(o, children)
        }
    }

    private func share(_ children: [Child], _ index: Int) -> Double {
        children[index].weight / children.reduce(0) { $0 + $1.weight }
    }

    /// Sets the share of child `index` (0…1), the others keeping their
    /// proportions; every share stays ≥ `minShare`.
    private mutating func setShare(at containerPath: [Int], index: Int, to wanted: Double, minShare: Double = 0.1) {
        update(containerPath) { node in
            guard case .split(let o, var children) = node, children.count > 1 else { return node }
            let others = children.count - 1
            let target = min(max(wanted, minShare), 1 - minShare * Double(others))
            let otherTotal = children.enumerated().filter { $0.offset != index }.reduce(0) { $0 + $1.element.weight }
            for i in children.indices {
                children[i].weight =
                    i == index
                    ? target
                    : max(
                        minShare, (1 - target) * (otherTotal > 0 ? children[i].weight / otherTotal : 1 / Double(others))
                    )
            }
            return .split(o, children)
        }
    }

    private static func averageWeight(_ children: [Child]) -> Double {
        children.isEmpty ? 1 : children.reduce(0) { $0 + $1.weight } / Double(children.count)
    }
}
