import Testing

@testable import PaveCore

@Suite struct RectTests {
    @Test func closeWithinTolerance() {
        let a = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(a.isClose(to: Rect(x: 1.5, y: -2, width: 101, height: 99)))
        #expect(!a.isClose(to: Rect(x: 3, y: 0, width: 100, height: 100)))
    }

    @Test func maxEdges() {
        let r = Rect(x: 10, y: 20, width: 30, height: 40)
        #expect(r.maxX == 40)
        #expect(r.maxY == 60)
    }
}
