import Testing
@testable import PaveCore

/// The LG on the left of the built-in screen, as plugged in.
private let lg = Screen(
    frame: Rect(x: -2560, y: 0, width: 2560, height: 1440),
    visibleFrame: Rect(x: -2560, y: 0, width: 2560, height: 1440), id: "LG")
private let builtIn = Screen(
    frame: Rect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrame: Rect(x: 0, y: 40, width: 1800, height: 1089), id: "BI")
private let screens = [builtIn, lg]
private let focus = ScreenZones(layout: ZoneSettings().layout(named: "focus")!, gaps: 8)
private func zonesOnLG(_ screen: Screen) -> ScreenZones? { screen.id == "LG" ? focus : nil }
private func zone(_ i: Int) -> Rect { focus.layout.frames(in: lg.visibleFrame, gaps: 8)[i] }

private func window(_ frame: Rect) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(1), pid: 1, appName: "App", title: "", frame: frame, state: .normal, subrole: "AXStandardWindow")
}

@Suite struct ZoneKeyboardTests {
    private func press(_ command: LayoutCommand, _ frame: Rect, _ engine: inout LayoutEngine) -> LayoutAction {
        engine.handle(command, window: window(frame), screens: screens, zones: zonesOnLG)
    }

    @Test func arrowsStepThroughTheZones() {
        var engine = LayoutEngine()
        #expect(press(.snapRight, zone(0), &engine) == .setFrame(zone(1)))
        #expect(press(.snapRight, zone(2), &engine) == .setFrame(zone(3)))
        #expect(press(.snapLeft, zone(1), &engine) == .setFrame(zone(0)))
    }

    @Test func aFloatingWindowGoesToTheZoneUnderItsCentreAndCanComeBack() {
        var engine = LayoutEngine()
        let free = Rect(x: -1500, y: 300, width: 600, height: 500)
        #expect(press(.snapLeft, free, &engine) == .setFrame(zone(1)))
        #expect(press(.restore, zone(1), &engine) == .setFrame(free))
    }

    @Test func pastTheLastZoneTheNeighbourScreen() {
        var engine = LayoutEngine()
        // Zone 4 is the LG's last: the built-in screen on its right, left half.
        #expect(press(.snapRight, zone(3), &engine) == .setFrame(Placement.left.frame(in: builtIn.visibleFrame)))
        #expect(press(.snapLeft, zone(0), &engine) == .none(reason: "last zone, no screen on the left"))
        // Back from the built-in's left half: the LG's last zone.
        #expect(press(.snapLeft, Placement.left.frame(in: builtIn.visibleFrame), &engine) == .setFrame(zone(3)))
    }

    @Test func upFillsTheScreenAndDownComesBack() {
        var engine = LayoutEngine()
        let free = Rect(x: -2000, y: 200, width: 700, height: 600)
        #expect(press(.maximize, free, &engine) == .setFrame(lg.visibleFrame))
        #expect(press(.maximize, lg.visibleFrame, &engine) == .none(reason: "already maximized"))
        #expect(press(.restore, lg.visibleFrame, &engine) == .setFrame(free))
    }

    @Test func downOnAZonedWindowRestoresItInsteadOfMinimizing() {
        var engine = LayoutEngine()
        let free = Rect(x: -2000, y: 200, width: 700, height: 600)
        _ = press(.snapRight, free, &engine)  // into zone 2 (centre at x -1650)
        #expect(press(.restore, zone(1), &engine) == .setFrame(free))
        #expect(press(.restore, free, &engine) == .minimize)
    }

    @Test func movingToAScreenWithoutZonesCarriesTheFrame() {
        var engine = LayoutEngine()
        guard case .setFrame(let moved) = press(.moveToScreenRight, zone(2), &engine) else {
            Issue.record("no move")
            return
        }
        #expect(builtIn.visibleFrame.contains(x: moved.x, y: moved.y))
    }

    @Test func zonesOffKeepHalves() {
        var engine = LayoutEngine()
        let free = Rect(x: -1500, y: 300, width: 600, height: 500)
        #expect(engine.handle(.snapLeft, window: window(free), screens: screens) == .setFrame(Placement.left.frame(in: lg.visibleFrame)))
    }

    @Test func aWindowLeavingACornerZoneStaysOnItsScreen() {
        var engine = LayoutEngine()
        let wide = Rect(x: -2552, y: 39, width: 2544, height: 1353)
        _ = engine.dragStarted(window(wide), cursorX: -1200, cursorY: 50, screens: screens)
        _ = engine.drop(window(wide), inZones: zone(2), screens: screens)
        // Grabbed near the right of zone 3: the full width would cross onto the built-in screen.
        let restored = engine.dragStarted(window(zone(2)), cursorX: -100, cursorY: 20, screens: screens)
        #expect(restored?.width == 2544)
        #expect(restored.map { $0.maxX <= 0 && $0.x >= -2560 } == true)
    }

    @Test func aWindowWiderThanItsZoneStillStepsOn() {
        // Prism refuses less than 900 pt; zone 1 is 628 pt wide.
        var engine = LayoutEngine()
        let free = Rect(x: -2400, y: 200, width: 900, height: 700)
        #expect(press(.snapLeft, free, &engine) == .setFrame(zone(0)))
        let centered = LayoutEngine.centered(width: 900, height: zone(0).height, in: zone(0))
        #expect(centered.x < lg.visibleFrame.x)  // off the screen's left edge
        let kept = LayoutEngine.keptOnScreen(centered, in: lg.visibleFrame)
        #expect(kept.x == lg.visibleFrame.x)
        engine.settled(WindowID(1), at: kept)
        #expect(press(.snapRight, kept, &engine) == .setFrame(zone(1)))
        // Centered without being moved back (a screen edge zone that fits) counts too.
        _ = press(.snapLeft, zone(1), &engine)
        #expect(press(.snapRight, centered, &engine) == .setFrame(zone(1)))
    }

    // MARK: Picker (⌃⇧Z)

    @Test func thePickerKeyIsGrabbedOnlyWithZonesOn() throws {
        var config = PaveConfig()
        #expect(HotkeyAction(configName: "zone-picker") == .zonePicker)
        #expect(!config.activeBindings.values.contains(.zonePicker))
        config.zones.enabled = true
        #expect(config.activeBindings[Hotkey(Hotkey.Key.z, [.control, .shift])] == .zonePicker)
    }

    @Test func thePickerListsBuiltInsThenTheUsersThenNone() throws {
        var settings = ZoneSettings()
        settings.layouts["Coding"] = try ZoneLayout(name: "Coding", zones: [.init(0, 0, 30, 100), .init(30, 0, 70, 100)])
        settings.layouts["focus"] = try ZoneLayout(name: "focus", zones: [.init(0, 0, 100, 100)])  // redefined
        #expect(settings.choices == ["focus", "thirds", "main-and-stack", "halves", "grid", "Coding", "none"])
    }

    @Test func aScreenWithoutKeyGetsAShortOne() {
        #expect(ZoneSettings.newScreenKey(screenID: "U", screenName: "LG ULTRAGEAR", isBuiltIn: false) == "LG")
        #expect(ZoneSettings.newScreenKey(screenID: "U", screenName: "Color LCD", isBuiltIn: true) == "builtin")
        #expect(ZoneSettings.newScreenKey(screenID: "U", screenName: "", isBuiltIn: false) == "U")
        var settings = ZoneSettings()
        settings.screens = ["LG": "focus"]
        #expect(settings.screenKey(screenID: "U", screenName: "LG ULTRAGEAR", isBuiltIn: false) == "LG")
    }

    @Test func windowsFollowTheNewLayout() {
        var engine = LayoutEngine()
        let thirds = ScreenZones(layout: ZoneSettings().layout(named: "thirds")!, gaps: 8)
        let thirdsFrames = thirds.layout.frames(in: lg.visibleFrame, gaps: 8)
        #expect(engine.reflow(window(zone(1)), from: focus, to: thirds, on: lg) == .setFrame(thirdsFrames[1]))
        #expect(engine.reflow(window(zone(3)), from: focus, to: thirds, on: lg) == .setFrame(thirdsFrames[2]))
        #expect(engine.reflow(window(Rect(x: -2000, y: 100, width: 500, height: 400)), from: focus, to: thirds, on: lg) == nil)
    }

    @Test func windowsFollowNewGapsToo() {
        var engine = LayoutEngine()
        let wider = ScreenZones(layout: focus.layout, gaps: 16)
        let target = focus.layout.frames(in: lg.visibleFrame, gaps: 16)[1]
        #expect(engine.reflow(window(zone(1)), from: focus, to: wider, on: lg) == .setFrame(target))
    }

    // MARK: App rule `zone = N`

    @Test func anAppRuleSendsNewWindowsToAZone() throws {
        let (config, _) = try PaveConfig.parse("[apps.\"com.prism\"]\nzone = 2")
        #expect(config.rule(for: "com.prism").zone == 2)
        #expect(config.rule(for: "com.prism").summary == "zone 2")
        #expect(throws: PaveConfig.Problem.self) { try PaveConfig.parse("[apps.\"com.prism\"]\nzone = 0") }
        var engine = LayoutEngine()
        let free = Rect(x: -2000, y: 200, width: 700, height: 600)
        #expect(engine.place(window(free), inZone: 1, of: focus, on: lg) == .setFrame(zone(1)))
        #expect(engine.place(window(free), inZone: 7, of: focus, on: lg) == nil)  // focus has 4 zones
        // It came from a floating frame: ⌃↓ gives it back.
        #expect(engine.handle(.restore, window: window(zone(1)), screens: screens, zones: zonesOnLG) == .setFrame(free))
    }

    // MARK: Zone picker (layout, then zone)

    @Test func placingAWindowAlreadyInAZoneKeepsItsFloatingFrame() {
        var engine = LayoutEngine()
        let free = Rect(x: -2000, y: 200, width: 700, height: 600)
        #expect(engine.place(window(free), inZone: 0, of: focus, on: lg) == .setFrame(zone(0)))
        #expect(engine.place(window(zone(0)), inZone: 3, of: focus, on: lg) == .setFrame(zone(3)))
        #expect(engine.place(window(zone(3)), inZone: 3, of: focus, on: lg) == nil)  // already there
        #expect(engine.handle(.restore, window: window(zone(3)), screens: screens, zones: zonesOnLG) == .setFrame(free))
    }
}
