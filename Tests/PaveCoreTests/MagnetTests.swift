import Testing
@testable import PaveCore

@Suite struct MagnetTests {
    let area = Rect(x: 0, y: 40, width: 1800, height: 1069)
    let left = Rect(x: 0, y: 40, width: 900, height: 1069)

    @Test func aWindowDroppedNearAnotherSticksToIt() {
        // 8 pt right of the window on the left, same top: against it.
        let dropped = Rect(x: 908, y: 300, width: 600, height: 400)
        #expect(Magnet.snap(dropped, to: [left], area: area, distance: 12) == Rect(x: 900, y: 300, width: 600, height: 400))
        // Overlapping it by 10 pt: pushed out to touch.
        #expect(Magnet.snap(Rect(x: 890, y: 300, width: 600, height: 400), to: [left], area: area, distance: 12).x == 900)
    }

    @Test func edgesOfTheScreenAndAlignmentCount() {
        let dropped = Rect(x: 1205, y: 46, width: 590, height: 400)
        // Right edge 5 pt from the screen's, top 6 pt below the area's.
        #expect(Magnet.snap(dropped, to: [], area: area, distance: 12) == Rect(x: 1210, y: 40, width: 590, height: 400))
        // Tops aligned with a window it faces (side by side).
        let other = Rect(x: 100, y: 200, width: 500, height: 500)
        #expect(Magnet.snap(Rect(x: 700, y: 207, width: 400, height: 300), to: [other], area: area, distance: 12).y == 200)
    }

    @Test func farOrDistantWindowsDoNotPull() {
        let dropped = Rect(x: 950, y: 300, width: 600, height: 400)
        #expect(Magnet.snap(dropped, to: [left], area: area, distance: 12) == dropped)
        #expect(Magnet.snap(Rect(x: 905, y: 300, width: 600, height: 400), to: [left], area: area, distance: 0).x == 905)
        // Same x as the left window's right edge, but far below it on the other axis: no pull.
        let high = Rect(x: 0, y: 40, width: 900, height: 200)
        #expect(Magnet.snap(Rect(x: 905, y: 700, width: 300, height: 300), to: [high], area: area, distance: 12).x == 905)
    }

    @Test func neighboursAreTheWindowsTouchingAnEdge() {
        let right = Rect(x: 908, y: 40, width: 892, height: 1069)  // a zone gap away
        let below = Rect(x: 0, y: 700, width: 900, height: 409)
        let top = Rect(x: 0, y: 40, width: 900, height: 652)
        let found = Magnet.neighbours(of: top, among: [(WindowID(2), right), (WindowID(3), below), (WindowID(4), Rect(x: 1300, y: 40, width: 500, height: 300))], tolerance: 24)
        #expect(found == [
            .init(id: WindowID(2), frame: right, edge: .right, gap: 8),
            .init(id: WindowID(3), frame: below, edge: .bottom, gap: 8),
        ])
    }

    @Test func aNeighbourFollowsTheSharedEdge() {
        let right = Magnet.Neighbour(id: WindowID(2), frame: Rect(x: 908, y: 40, width: 892, height: 1069), edge: .right, gap: 8)
        let wider = Rect(x: 0, y: 40, width: 1100, height: 1069)
        #expect(Magnet.movedEdges(from: left, to: wider) == [.right])
        #expect(Magnet.follow(right, resized: wider) == Rect(x: 1108, y: 40, width: 692, height: 1069))
        // It keeps a minimum size: the far edge stays.
        let huge = Rect(x: 0, y: 40, width: 1750, height: 1069)
        #expect(Magnet.follow(right, resized: huge) == Rect(x: 1680, y: 40, width: 120, height: 1069))
        let shrunk = Magnet.Neighbour(id: WindowID(3), frame: left, edge: .left, gap: 8)
        #expect(Magnet.follow(shrunk, resized: Rect(x: 700, y: 40, width: 1100, height: 1069)).width == 692)
    }

    @Test func configReadsTheWindowsSection() throws {
        let config = try PaveConfig.parse("[windows]\nmagnet = 0\nresize-neighbours = false").config
        #expect(config.windowMagnet == 0 && !config.resizeNeighbours)
        #expect(PaveConfig.default.windowMagnet == 12 && PaveConfig.default.resizeNeighbours)
        #expect(throws: PaveConfig.Problem.self) { try PaveConfig.parse("[windows]\nmagnet = 100") }
    }

    // MARK: Fill

    @Test func againstAWindowItFillsTheFreeThird() {
        let twoThirds = Rect(x: 600, y: 40, width: 1200, height: 1069)
        let snapped = Rect(x: 100, y: 300, width: 500, height: 400)  // against its left edge
        #expect(Magnet.fill(snapped, point: (300, 320), others: [twoThirds], area: area) == Rect(x: 0, y: 40, width: 600, height: 1069))
    }

    @Test func theFreeSpaceIsBoundedByEveryWindow() {
        // Right half split in two; the top-left quarter taken: the drop fills the bottom-left quarter.
        let rightTop = Rect(x: 900, y: 40, width: 900, height: 534)
        let rightBottom = Rect(x: 900, y: 574, width: 900, height: 535)
        let leftTop = Rect(x: 0, y: 40, width: 900, height: 534)
        let snapped = Rect(x: 300, y: 600, width: 600, height: 300)
        #expect(Magnet.fill(snapped, point: (500, 620), others: [rightTop, rightBottom, leftTop], area: area)
            == Rect(x: 0, y: 574, width: 900, height: 535))
    }

    @Test func noFillAgainstTheScreenAloneOrInATinySpace() {
        let alone = Rect(x: 0, y: 40, width: 500, height: 400)
        #expect(Magnet.fill(alone, point: (100, 60), others: [], area: area) == nil)
        let wide = Rect(x: 0, y: 40, width: 1700, height: 1069)
        let squeezed = Rect(x: 1700, y: 300, width: 300, height: 300)
        #expect(Magnet.fill(squeezed, point: (1750, 320), others: [wide], area: area) == nil)  // 100 pt wide
    }
}
