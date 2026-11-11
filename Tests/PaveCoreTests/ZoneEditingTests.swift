// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import PaveCore

private func layout(_ name: String) -> ZoneLayout { ZoneSettings().layout(named: name)! }

@Suite struct ZoneEditingTests {
    @Test func splittingCutsNearTheMiddleOnTheStep() {
        var draft = ZoneDraft(layout("halves"))
        let r1 = draft.split(0, columns: true)
        #expect(r1 == 0)
        #expect(draft.zones == [.init(0, 0, 25, 100), .init(25, 0, 25, 100), .init(50, 0, 50, 100)])
        let r2 = draft.split(2, columns: false)
        #expect(r2 == 2)
        #expect(draft.zones[2] == .init(50, 0, 50, 50) && draft.zones[3] == .init(50, 50, 50, 50))
        // 33 wide: the middle (16) is off the step, 15 keeps both halves big enough.
        var thirds = ZoneDraft(layout("thirds"))
        _ = thirds.split(0, columns: true)
        #expect(thirds.zones[0] == .init(0, 0, 15, 100))
    }

    @Test func aZoneTooSmallIsNotCut() {
        var draft = ZoneDraft(zones: [.init(0, 0, 8, 100), .init(8, 0, 92, 100)])
        let r3 = draft.split(0, columns: true)
        #expect(r3 == nil)
        #expect(!draft.canUndo)
    }

    @Test func onlyZonesMakingARectangleMerge() {
        var draft = ZoneDraft(layout("focus"))
        let r4 = draft.merge(0, 2)
        #expect(r4 == nil)  // zone 1 and zone 3 are not neighbours
        let r5 = draft.merge(2, 3)
        #expect(r5 == 2)  // zones 3 and 4: the right column
        #expect(draft.zones == [.init(0, 0, 25, 100), .init(25, 0, 50, 100), .init(75, 0, 25, 100)])
        let r6 = draft.merge(0, 1)
        #expect(r6 == 0)
        #expect(draft.zones == [.init(0, 0, 75, 100), .init(75, 0, 25, 100)])
    }

    @Test func removingLeavesAHoleButNeverNothing() {
        var draft = ZoneDraft(layout("halves"))
        let r7 = draft.remove(0)
        #expect(r7)
        #expect(draft.zones == [.init(50, 0, 50, 100)])
        let removed = draft.remove(0)
        #expect(!removed)
    }

    @Test func undoGoesBackStepByStep() {
        var draft = ZoneDraft(layout("halves"))
        _ = draft.split(0, columns: true)
        _ = draft.merge(0, 1)
        draft.undo()
        #expect(draft.zones.count == 3)
        draft.undo()
        #expect(draft.zones == layout("halves").zones)
        #expect(!draft.canUndo)
    }

    @Test func separatorsAreTheInnerEdges() {
        let draft = ZoneDraft(layout("focus"))
        let lines = draft.separators.map { "\($0.vertical ? "x" : "y")=\($0.position) \($0.start)-\($0.end)" }
        #expect(lines == ["x=25 0-100", "x=75 0-100", "y=50 75-100"])
        // A grid's rows move each column's piece on its own.
        #expect(ZoneDraft(layout("grid")).separators.filter(\.vertical).count == 4)
    }

    @Test func movingASeparatorResizesBothSidesOnTheStep() {
        var draft = ZoneDraft(layout("focus"))
        let line = draft.separators.first { $0.vertical && $0.position == 75 }!
        draft.beginMove()
        let moved = draft.move(line, to: 68)
        #expect(moved.position == 70)
        #expect(
            draft.zones == [.init(0, 0, 25, 100), .init(25, 0, 45, 100), .init(70, 0, 30, 50), .init(70, 50, 30, 50)])
        // Free with ⇧ (step 1), and never past the minimum size.
        draft.move(moved, to: 68, step: 1)
        #expect(draft.zones[1].width == 43)
        draft.move(draft.separators.first { $0.vertical && $0.position == 68 }!, to: 0)
        #expect(draft.zones[1] == .init(25, 0, 5, 100))
        draft.undo()
        #expect(draft.zones == layout("focus").zones)
    }

    @Test func anEdgeNextToAHoleStopsAtTheNextZone() {
        var draft = ZoneDraft(zones: [.init(0, 0, 40, 100), .init(60, 0, 40, 100)])
        let edge = draft.separators.first { $0.position == 40 }!
        #expect(draft.range(of: edge) == 5...60)
        draft.move(edge, to: 100)
        #expect(draft.zones[0] == .init(0, 0, 60, 100))
    }

    @Test func layoutsWriteBackToTheConfig() throws {
        let saved = try ZoneDraft(layout("focus")).layout(named: "Coding")
        #expect(saved.tomlZones == "[[0, 0, 25, 100], [25, 0, 50, 100], [75, 0, 25, 50], [75, 50, 25, 50]]")
        let (config, _) = try PaveConfig.parse("[layouts.\"My Coding\"]\nzones = \(saved.tomlZones)")
        #expect(config.zones.layouts["My Coding"]?.zones == saved.zones)
        #expect(
            ZoneLayout.isValidName("My Coding") && !ZoneLayout.isValidName("a\"b") && !ZoneLayout.isValidName("none"))
    }
}
