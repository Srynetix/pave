import Testing
@testable import PaveCore

/// An ultrawide's usable area, round numbers.
private let area = Rect(x: 0, y: 0, width: 3440, height: 1400)
private let focus = ZoneSettings().layout(named: "focus")!

@Suite struct ZoneLayoutTests {
    // MARK: Layouts

    @Test func zonesAreNumberedByColumnThenRow() throws {
        let layout = try ZoneLayout(name: "x", zones: [.init(50, 50, 50, 50), .init(0, 0, 50, 100), .init(50, 0, 50, 50)])
        #expect(layout.zones == [.init(0, 0, 50, 100), .init(50, 0, 50, 50), .init(50, 50, 50, 50)])
    }

    @Test func invalidLayoutsAreRefused() {
        #expect(throws: ZoneLayout.Invalid.self) { try ZoneLayout(name: "x", zones: []) }
        #expect(throws: ZoneLayout.Invalid(message: "zone 1 [60, 0, 50, 100] must stay within 0 to 100 %")) {
            try ZoneLayout(name: "x", zones: [.init(60, 0, 50, 100)])
        }
        #expect(throws: ZoneLayout.Invalid(message: "zones 1 and 2 overlap")) {
            try ZoneLayout(name: "x", zones: [.init(0, 0, 60, 100), .init(50, 0, 50, 100)])
        }
        // Holes are fine.
        #expect((try? ZoneLayout(name: "x", zones: [.init(0, 0, 40, 100), .init(60, 0, 40, 100)])) != nil)
    }

    @Test func builtInLayoutsAreValidAndCoverTheScreen() {
        for layout in ZoneLayout.builtIn {
            #expect(layout.zones.reduce(0) { $0 + $1.width * $1.height } == 100 * 100, "\(layout.name)")
        }
    }

    // MARK: Geometry

    @Test func cellsShareTheirEdges() {
        #expect(focus.cells(in: area) == [
            Rect(x: 0, y: 0, width: 860, height: 1400), Rect(x: 860, y: 0, width: 1720, height: 1400),
            Rect(x: 2580, y: 0, width: 860, height: 700), Rect(x: 2580, y: 700, width: 860, height: 700),
        ])
    }

    @Test func gapsAreEqualAtTheEdgesAndBetweenZones() {
        let frames = focus.frames(in: area, gaps: 8)
        #expect(frames == [
            Rect(x: 8, y: 8, width: 848, height: 1384), Rect(x: 864, y: 8, width: 1712, height: 1384),
            Rect(x: 2584, y: 8, width: 848, height: 688), Rect(x: 2584, y: 704, width: 848, height: 688),
        ])
        #expect(frames[1].x - frames[0].maxX == 8)
        #expect(frames[3].y - frames[2].maxY == 8)
    }

    @Test func oddGapsStayIntegralAndEqual() {
        let frames = focus.frames(in: area, gaps: 5)
        #expect(frames[1].x - frames[0].maxX == 5)
        #expect(frames.allSatisfy { $0.x == $0.x.rounded() && $0.width == $0.width.rounded() })
    }

    @Test func roundingNeverLeavesAGap() {
        let odd = Rect(x: 13, y: 37, width: 1727, height: 1079)
        let cells = ZoneLayout.builtIn.first { $0.name == "thirds" }!.cells(in: odd)
        #expect(cells[0].maxX == cells[1].x && cells[1].maxX == cells[2].x && cells[2].maxX == odd.maxX)
    }

    @Test func theZoneUnderThePointer() throws {
        #expect(focus.zone(atX: 100, y: 700, in: area) == 0)
        #expect(focus.zone(atX: 860, y: 10, in: area) == 1)  // on the shared edge: the right one
        #expect(focus.zone(atX: 3000, y: 699, in: area) == 2)
        #expect(focus.zone(atX: 3000, y: 700, in: area) == 3)
        #expect(focus.zone(atX: 5000, y: 1300, in: area) == 3)  // off the area: the nearest
        let holes = try ZoneLayout(name: "x", zones: [.init(0, 0, 40, 100), .init(60, 0, 40, 100)])
        #expect(holes.zone(atX: 1500, y: 500, in: area) == 0)
        #expect(holes.zone(atX: 1900, y: 500, in: area) == 1)
    }

    // MARK: Spans

    @Test func spanningTwoZones() {
        let span = focus.span(0, 1, in: area, gaps: 8)
        #expect(span.zones == [0, 1])
        #expect(span.frame == Rect(x: 8, y: 8, width: 2568, height: 1384))
    }

    @Test func aSpanTakesEveryZoneInItsBox() {
        // Zone 2 to zone 3 (top right): the box is the whole width, zone 4 is in it.
        #expect(focus.span(1, 2, in: area).zones == [1, 2, 3])
        #expect(focus.span(2, 3, in: area, gaps: 8).frame == Rect(x: 2584, y: 8, width: 848, height: 1384))
        #expect(focus.span(2, 2, in: area).zones == [2])
    }

    // MARK: Which zones a window fills (Z-e)

    @Test func aWindowIsInTheZoneItFills() {
        let frames = focus.frames(in: area, gaps: 8)
        #expect(focus.zones(matching: frames[2], in: area, gaps: 8) == [2])
        // An app a point off still counts.
        var off = frames[1]
        off.width -= 2
        #expect(focus.zones(matching: off, in: area, gaps: 8) == [1])
        #expect(focus.zones(matching: focus.span(0, 1, in: area, gaps: 8).frame, in: area, gaps: 8) == [0, 1])
        #expect(focus.zones(matching: Rect(x: 300, y: 200, width: 900, height: 600), in: area, gaps: 8) == nil)
        // A box over two zones but larger than them is not a span.
        #expect(focus.zones(matching: Rect(x: 0, y: 0, width: 3000, height: 1400), in: area, gaps: 8) == nil)
    }

    // MARK: Keyboard

    @Test func stepsFollowTheZoneNumbers() {
        let frames = focus.frames(in: area, gaps: 8)
        #expect(focus.step(from: frames[1], forward: true, in: area, gaps: 8) == 2)
        #expect(focus.step(from: frames[1], forward: false, in: area, gaps: 8) == 0)
        #expect(focus.step(from: frames[3], forward: true, in: area, gaps: 8) == nil)  // next screen
        #expect(focus.step(from: frames[0], forward: false, in: area, gaps: 8) == nil)
    }

    @Test func aSpanStepsFromItsEnds() {
        let span = focus.span(0, 1, in: area, gaps: 8).frame
        #expect(focus.step(from: span, forward: true, in: area, gaps: 8) == 2)
        #expect(focus.step(from: span, forward: false, in: area, gaps: 8) == nil)
    }

    @Test func aFreeWindowGoesToTheZoneUnderItsCentre() {
        let free = Rect(x: 2000, y: 900, width: 1000, height: 400)  // centre (2500, 1100)
        #expect(focus.step(from: free, forward: true, in: area, gaps: 8) == 1)
        #expect(focus.step(from: free, forward: false, in: area, gaps: 8) == 1)
    }

    // MARK: Switching layouts

    @Test func windowsFollowANewLayout() {
        let thirds = ZoneLayout.builtIn.first { $0.name == "thirds" }!
        let halves = ZoneLayout.builtIn.first { $0.name == "halves" }!
        let frames = focus.frames(in: area, gaps: 8)
        #expect(thirds.reflow(frames[1], from: focus, in: area, gaps: 8) == thirds.frames(in: area, gaps: 8)[1])
        // Zone 4 does not exist in thirds: the last zone.
        #expect(thirds.reflow(frames[3], from: focus, in: area, gaps: 8) == thirds.frames(in: area, gaps: 8)[2])
        // A span of zones 1 + 2 stays a span when it can.
        let span = focus.span(0, 1, in: area, gaps: 8).frame
        #expect(thirds.reflow(span, from: focus, in: area, gaps: 8) == thirds.frame(of: [0, 1], in: area, gaps: 8))
        #expect(halves.reflow(frames[3], from: focus, in: area, gaps: 8) == halves.frames(in: area, gaps: 8)[1])
        #expect(thirds.reflow(Rect(x: 100, y: 100, width: 500, height: 500), from: focus, in: area, gaps: 8) == nil)
    }

    // MARK: Settings

    @Test func screensFindTheirLayout() throws {
        var settings = ZoneSettings()
        settings.enabled = true
        settings.screens = ["builtin": "none", "LG": "focus", "ABCDEF01-2345-4678-9ABC-DEF012345678": "thirds"]
        settings.workspaces = [3: "main-and-stack", 4: "none"]
        #expect(settings.layout(screenID: "X", screenName: "LG HDR WQHD", isBuiltIn: false)?.name == "focus")
        #expect(settings.layout(screenID: "X", screenName: "Built-in Retina Display", isBuiltIn: true) == nil)
        // The UUID wins over the name.
        #expect(settings.layout(screenID: "abcdef01-2345-4678-9abc-def012345678", screenName: "LG HDR WQHD", isBuiltIn: false)?.name == "thirds")
        #expect(settings.layout(screenID: "X", screenName: "DELL U2720Q", isBuiltIn: false) == nil)
        // Workspace overrides, only where the screen has a layout.
        #expect(settings.layout(screenID: "X", screenName: "LG HDR WQHD", isBuiltIn: false, workspace: 3)?.name == "main-and-stack")
        #expect(settings.layout(screenID: "X", screenName: "LG HDR WQHD", isBuiltIn: false, workspace: 4) == nil)
        #expect(settings.layout(screenID: "X", screenName: "Built-in Retina Display", isBuiltIn: true, workspace: 3) == nil)
        settings.enabled = false
        #expect(settings.layout(screenID: "X", screenName: "LG HDR WQHD", isBuiltIn: false) == nil)
    }

    @Test func theConfigFileDefinesZones() throws {
        let text = """
            [zones]
            enabled = true
            gaps = 6
            show = "ctrl"
            keyboard = false

            [zones.screens]
            builtin = "none"
            LG = "Coding"

            [zones.workspaces]
            3 = "thirds"

            [layouts."Coding"]
            zones = [[0, 0, 30, 100], [30, 0, 45, 100],
                     [75, 0, 25, 60], [75, 60, 25, 40]]
            """
        let (config, warnings) = try PaveConfig.parse(text)
        #expect(warnings.isEmpty)
        #expect(config.zones.enabled && config.zones.gaps == 6 && config.zones.show == .ctrl && !config.zones.keyboard)
        #expect(config.zones.screens == ["builtin": "none", "LG": "Coding"])
        #expect(config.zones.workspaces == [3: "thirds"])
        #expect(config.zones.layouts["Coding"]?.zones.count == 4)
        #expect(config.zones.layout(screenID: "", screenName: "LG HDR WQHD", isBuiltIn: false)?.name == "Coding")
    }

    @Test func zoneErrorsPointAtTheirLine() {
        func problem(_ text: String) -> PaveConfig.Problem? {
            do { _ = try PaveConfig.parse(text); return nil } catch { return error }
        }
        #expect(problem("[zones.screens]\nLG = \"focsu\"")?.message.hasPrefix("zones.screens.LG must be a layout:") == true)
        #expect(problem("[zones.screens]\nLG = \"focsu\"")?.line == 2)
        #expect(problem("[layouts.\"A\"]\nzones = [[0, 0, 60, 100], [50, 0, 50, 100]]")?.message == "layout \"A\": zones 1 and 2 overlap")
        #expect(problem("[layouts.\"A\"]\nzones = [[0, 0, 100]]")?.line == 2)
        #expect(problem("[zones.workspaces]\n12 = \"thirds\"") != nil)
        #expect(problem("[zones]\ngaps = 100") != nil)
    }
}
