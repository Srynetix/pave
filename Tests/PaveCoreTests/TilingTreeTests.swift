import Foundation
import Testing

@testable import PaveCore

private func w(_ n: UInt32) -> WindowID { WindowID(n) }

/// "H[1 2 V[3 4]]": the tree's shape, weights left out.
private func shape(_ tree: TilingTree) -> String {
    func text(_ node: TilingTree.Node) -> String {
        switch node {
        case .window(let id): "\(id.rawValue)"
        case .split(let o, let children):
            (o == .horizontal ? "H[" : "V[") + children.map { text($0.node) }.joined(separator: " ") + "]"
        }
    }
    return text(tree.root)
}

/// Builds H[1 2 …] with `n` windows.
private func row(_ n: UInt32) -> TilingTree {
    var tree = TilingTree()
    for i in 1...n { tree.insert(w(i), after: i > 1 ? w(i - 1) : nil) }
    return tree
}

private let area = Rect(x: 0, y: 40, width: 1800, height: 1089)

@Suite struct TilingTreeTests {
    // MARK: Insert / remove / normalize

    @Test func windowsGoAfterTheFocusedOne() {
        var tree = row(3)
        tree.insert(w(9), after: w(1))
        #expect(shape(tree) == "H[1 9 2 3]")
        tree.insert(w(8))
        #expect(shape(tree) == "H[1 9 2 3 8]")
        tree.insert(w(8))  // already there
        #expect(tree.windows.count == 5)
    }

    @Test func removingCollapsesSingleChildContainers() {
        var tree = row(2)
        tree.toggleOrientation(of: w(2))  // root becomes vertical: V[1 2]
        tree.insert(w(3), after: w(2))
        #expect(shape(tree) == "V[1 2 3]")
        tree.remove(w(2))
        tree.remove(w(3))
        #expect(shape(tree) == "V[1]")
        tree.remove(w(1))
        #expect(tree.isEmpty)
    }

    @Test func nestedContainersAlternate() {
        var tree = row(3)
        #expect(tree.move(w(3), .down) == .moved)  // wraps the root: V[H[1 2] 3]
        #expect(shape(tree) == "V[H[1 2] 3]")
        tree.toggleOrientation(of: w(1))  // H[1 2] becomes V: merged into the root
        #expect(shape(tree) == "V[1 2 3]")
    }

    // MARK: Frames

    @Test func framesCoverTheAreaExactlyWithGaps() {
        let tree = row(3)
        let frames = tree.frames(in: area, gaps: 8)
        let f = [frames[w(1)]!, frames[w(2)]!, frames[w(3)]!]
        #expect(f[0].x == 8 && f[0].y == 48 && f[0].height == 1089 - 16)
        #expect(f[1].x == f[0].maxX + 8 && f[2].x == f[1].maxX + 8)
        #expect(f[2].maxX == 1800 - 8)  // the last one takes the rounding remainder
        #expect(abs(f[0].width - f[1].width) <= 1)
    }

    @Test func nestedFrames() {
        var tree = row(2)
        tree.insert(w(3), after: w(2))
        _ = tree.move(w(3), .down)  // V[H[1 2] 3]
        let frames = tree.frames(in: Rect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(frames[w(1)] == Rect(x: 0, y: 0, width: 500, height: 500))
        #expect(frames[w(2)] == Rect(x: 500, y: 0, width: 500, height: 500))
        #expect(frames[w(3)] == Rect(x: 0, y: 500, width: 1000, height: 500))
    }

    // MARK: Move

    @Test func moveSwapsWithTheNeighbour() {
        var tree = row(3)
        #expect(tree.move(w(1), .right) == .moved)
        #expect(shape(tree) == "H[2 1 3]")
        #expect(tree.move(w(1), .left) == .moved)
        #expect(shape(tree) == "H[1 2 3]")
    }

    @Test func moveAgainstTheEdgeIsReportedForTheNextScreen() {
        var tree = row(2)
        #expect(tree.move(w(1), .left) == .atEdge)
        #expect(tree.move(w(2), .right) == .atEdge)
        #expect(shape(tree) == "H[1 2]")
        #expect(tree.move(w(99), .left) == .unknownWindow)
    }

    @Test func movingAcrossTheRootOrientationWrapsIt() {
        var tree = row(2)
        #expect(tree.move(w(2), .up) == .moved)
        #expect(shape(tree) == "V[2 1]")
        var lone = row(1)
        #expect(lone.move(w(1), .down) == .atEdge)  // nothing to split with
    }

    @Test func moveEntersANeighbourContainer() {
        var tree = row(3)
        _ = tree.move(w(3), .down)  // V[H[1 2] 3]
        #expect(tree.move(w(3), .up) == .moved)  // into H[1 2], on its near (bottom) side…
        // …a horizontal container has no "bottom": the window goes at its end.
        #expect(shape(tree) == "H[1 2 3]")
    }

    @Test func moveLeavesItsContainerTowardsAnAncestor() {
        var tree = row(4)
        _ = tree.move(w(3), .down)  // the root wraps: V[H[1 2 4] 3]
        #expect(shape(tree) == "V[H[1 2 4] 3]")
        #expect(tree.move(w(4), .down) == .moved)  // 4 leaves H, below it: V[H[1 2] 4 3]
        #expect(shape(tree) == "V[H[1 2] 4 3]")
        #expect(tree.move(w(1), .up) == .moved)  // 1 leaves H, above it
        #expect(shape(tree) == "V[1 2 4 3]")
    }

    @Test func aWindowAtTheEdgeOfADeepContainerEscapesToTheAncestor() {
        var tree = row(4)
        _ = tree.move(w(4), .down)  // V[H[1 2 3] 4]
        _ = tree.move(w(1), .up)  // V[1 H[2 3] 4]
        _ = tree.move(w(4), .right)  // H[V[1 H[2 3]] 4]
        #expect(shape(tree) == "H[V[1 H[2 3]] 4]")
        // 2 is at the left edge of H[2 3]: it goes left of V, in the root.
        #expect(tree.move(w(2), .left) == .moved)
        #expect(shape(tree) == "H[2 V[1 3] 4]")
    }

    // MARK: Resize

    @Test func resizeGrowsAndShrinksWithinBounds() {
        var tree = row(2)
        tree.resize(w(1), .right, step: 0.1)
        var frames = tree.frames(in: Rect(x: 0, y: 0, width: 1000, height: 500))
        #expect(frames[w(1)]?.width == 600)
        for _ in 0..<20 { tree.resize(w(1), .right, step: 0.1) }
        frames = tree.frames(in: Rect(x: 0, y: 0, width: 1000, height: 500))
        #expect(frames[w(2)]?.width == 100)  // never below 10 %
        tree.resize(w(1), .up)  // no vertical container: nothing
        #expect(tree.frames(in: Rect(x: 0, y: 0, width: 1000, height: 500)) == frames)
    }

    @Test func mouseResizeBecomesTheNewShare() {
        var tree = row(2)
        let r = Rect(x: 0, y: 0, width: 1000, height: 500)
        let before = tree.frames(in: r)[w(1)]!
        var after = before
        after.width += 200  // dragged its right border
        tree.resized(w(1), from: before, to: after, in: r)
        #expect(tree.frames(in: r)[w(1)]?.width == 700)
        #expect(tree.frames(in: r)[w(2)]?.width == 300)
    }

    @Test func mouseResizeWithGaps() {
        var tree = row(2)
        let before = tree.frames(in: area, gaps: 8)[w(1)]!
        var after = before
        after.width -= 100
        tree.resized(w(1), from: before, to: after, in: area, gaps: 8)
        let now = tree.frames(in: area, gaps: 8)[w(1)]!
        #expect(abs(now.width - after.width) <= 1)
    }

    // MARK: Swap, neighbours, persistence

    @Test func swapExchangesTiles() {
        var tree = row(3)
        tree.swap(w(1), w(3))
        #expect(shape(tree) == "H[3 2 1]")
    }

    @Test func neighbourFollowsTheGeometry() {
        var tree = row(2)
        tree.insert(w(3), after: w(2))
        _ = tree.move(w(3), .down)  // V[H[1 2] 3]
        let frames = tree.frames(in: Rect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(TilingTree.neighbour(of: w(1), .right, frames: frames) == w(2))
        #expect(TilingTree.neighbour(of: w(2), .down, frames: frames) == w(3))
        #expect(TilingTree.neighbour(of: w(3), .up, frames: frames) == w(1))  // overlaps both: the first by ID
        #expect(TilingTree.neighbour(of: w(1), .left, frames: frames) == nil)
    }

    @Test func survivesJSONRoundTrip() throws {
        var tree = row(3)
        _ = tree.move(w(3), .down)
        tree.resize(w(1), .right)
        let data = try JSONEncoder().encode(tree)
        #expect(try JSONDecoder().decode(TilingTree.self, from: data) == tree)
    }
}
