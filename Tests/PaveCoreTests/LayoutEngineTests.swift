// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import PaveCore

private let screen = Screen(
    frame: Rect(x: 0, y: 0, width: 1801, height: 1169),
    visibleFrame: Rect(x: 0, y: 40, width: 1801, height: 1069))

private func window(_ frame: Rect, state: WindowState = .normal) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(1), pid: 1, appName: "App", title: "", frame: frame, state: state,
        subrole: "AXStandardWindow")
}

private let floating = Rect(x: 200, y: 150, width: 640, height: 480)

@Suite struct LayoutEngineTests {
    @Test func halvesTileTheAreaWithoutGap() {
        let left = LayoutEngine.target(.snapLeft, in: screen.visibleFrame)
        let right = LayoutEngine.target(.snapRight, in: screen.visibleFrame)
        #expect(left == Rect(x: 0, y: 40, width: 900, height: 1069))
        #expect(right == Rect(x: 900, y: 40, width: 901, height: 1069))
        #expect(left.maxX == right.x)
    }

    @Test func snapRemembersOriginalFrameOnce() {
        var engine = LayoutEngine()
        #expect(
            engine.handle(.snapLeft, window: window(floating), screen: screen)
                == .setFrame(LayoutEngine.target(.snapLeft, in: screen.visibleFrame)))
        // Second placement must not overwrite the original frame.
        let left = LayoutEngine.target(.snapLeft, in: screen.visibleFrame)
        _ = engine.handle(.maximize, window: window(left), screen: screen)
        #expect(engine.restoreFrames[WindowID(1)] == floating)
    }

    @Test func restoreGoesBackThenMinimizes() {
        var engine = LayoutEngine()
        _ = engine.handle(.maximize, window: window(floating), screen: screen)
        #expect(engine.handle(.restore, window: window(screen.visibleFrame), screen: screen) == .setFrame(floating))
        #expect(engine.handle(.restore, window: window(floating), screen: screen) == .minimize)
    }

    @Test func noOpWhenAlreadyInPlace() {
        var engine = LayoutEngine()
        let action = engine.handle(.maximize, window: window(screen.visibleFrame), screen: screen)
        #expect(action == .none(reason: "already maximized"))
        #expect(engine.restoreFrames.isEmpty)
    }

    @Test func ignoresMinimizedAndFullscreenWindows() {
        var engine = LayoutEngine()
        #expect(
            engine.handle(.snapLeft, window: window(floating, state: .minimized), screen: screen)
                == .none(reason: "window is minimized"))
        #expect(
            engine.handle(.restore, window: window(floating, state: .fullscreen), screen: screen)
                == .none(reason: "window is fullscreen"))
    }

    @Test func forgetDropsRestoreFrame() {
        var engine = LayoutEngine()
        _ = engine.handle(.snapRight, window: window(floating), screen: screen)
        engine.forget(WindowID(1))
        #expect(engine.handle(.restore, window: window(floating), screen: screen) == .minimize)
    }

    @Test func picksScreenWithLargestOverlap() {
        let second = Screen(
            frame: Rect(x: 1801, y: 0, width: 1920, height: 1080),
            visibleFrame: Rect(x: 1801, y: 25, width: 1920, height: 1055))
        let mostlyOnSecond = Rect(x: 1700, y: 100, width: 800, height: 600)
        #expect(LayoutEngine.screen(for: mostlyOnSecond, among: [screen, second]) == second)
        #expect(
            LayoutEngine.screen(for: Rect(x: -5000, y: 0, width: 10, height: 10), among: [screen, second]) == screen)
    }

    @Test func constrainedResultIsOkWhenCentered() {
        let target = Rect(x: 0, y: 40, width: 900, height: 1069)
        let centered = LayoutEngine.centered(width: 700, height: 600, in: target)
        #expect(centered == Rect(x: 100, y: 275, width: 700, height: 600))
        let result = MoveResult(
            window: 1, target: target, actual: centered, constrained: true, durationMs: 5, error: nil)
        #expect(result.ok)
        let off = MoveResult(window: 1, target: target, actual: floating, constrained: false, durationMs: 5, error: nil)
        #expect(!off.ok)
    }
}

// MARK: - Quarters and several screens

/// External 1920×1080 screen to the right of the built-in one, with no menu bar.
private let rightScreen = Screen(
    frame: Rect(x: 1801, y: 0, width: 1920, height: 1080), visibleFrame: Rect(x: 1801, y: 0, width: 1920, height: 1080))
/// The same, to the left (negative x in AX coordinates).
private let leftScreen = Screen(
    frame: Rect(x: -1920, y: 100, width: 1920, height: 1080),
    visibleFrame: Rect(x: -1920, y: 100, width: 1920, height: 1080))
/// Above the built-in screen (negative y).
private let aboveScreen = Screen(
    frame: Rect(x: 0, y: -1080, width: 1920, height: 1080),
    visibleFrame: Rect(x: 0, y: -1080, width: 1920, height: 1080))

private func at(_ placement: Placement, _ s: Screen = screen) -> Rect { placement.frame(in: s.visibleFrame) }

@Suite struct LayoutTransitionTests {
    /// Runs `commands` from `start`, applying each frame like the real window would.
    private func run(_ commands: [LayoutCommand], from start: Rect, screens: [Screen] = [screen]) -> [LayoutAction] {
        var engine = LayoutEngine()
        var frame = start
        return commands.map { command in
            let action = engine.handle(command, window: window(frame), screens: screens)
            if case .setFrame(let next) = action { frame = next }
            return action
        }
    }

    @Test func quartersTileTheArea() {
        let area = screen.visibleFrame
        let quarters: [Placement] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        #expect(quarters.map { $0.frame(in: area).area }.reduce(0, +) == area.area)
        #expect(at(.topLeft).maxY == at(.bottomLeft).y)
        #expect(at(.topLeft).maxX == at(.topRight).x)
    }

    @Test func upAndDownFromAHalfGiveQuarters() {
        // Windows 11: ← then ↑ = top-left quarter; ↓ goes back to the half, ↓ again = bottom quarter.
        #expect(
            run([.snapLeft, .maximize, .restore, .restore], from: floating)
                == [.setFrame(at(.left)), .setFrame(at(.topLeft)), .setFrame(at(.left)), .setFrame(at(.bottomLeft))])
        // From a bottom quarter: ↑ = the half; from a top quarter: ↑ = maximized.
        #expect(
            run([.snapRight, .restore, .maximize, .maximize, .maximize], from: floating)
                == [
                    .setFrame(at(.right)), .setFrame(at(.bottomRight)), .setFrame(at(.right)), .setFrame(at(.topRight)),
                    .setFrame(at(.maximized)),
                ])
        // ↓ on a bottom quarter minimizes, as Windows does.
        #expect(run([.snapLeft, .restore, .restore], from: floating).last == .minimize)
    }

    @Test func maximizedThenDownRestoresTheFloatingFrame() {
        #expect(
            run([.maximize, .restore, .restore], from: floating)
                == [.setFrame(at(.maximized)), .setFrame(floating), .minimize])
        // Through quarters and halves, the frame to restore stays the floating one.
        #expect(run([.snapLeft, .maximize, .maximize, .restore], from: floating).last == .setFrame(floating))
    }

    @Test func oppositeArrowOnAHalfGoesBackToFloating() {
        // Windows: right half + Win+← = restored, then Win+← = left half.
        #expect(
            run([.snapRight, .snapLeft, .snapLeft], from: floating)
                == [.setFrame(at(.right)), .setFrame(floating), .setFrame(at(.left))])
        // Quarters slide to the other side, keeping their row.
        #expect(run([.snapRight, .maximize, .snapLeft], from: floating).last == .setFrame(at(.topLeft)))
    }

    @Test func halfAgainstTheEdgeContinuesOnTheNeighbourScreen() {
        let screens = [screen, rightScreen]
        // → → → →: right half, left half of the external screen, floating *on the
        // external screen* (Windows restores on the current screen), its right half.
        let restoredThere = LayoutEngine.carry(floating, from: screen.visibleFrame, to: rightScreen.visibleFrame)
        #expect(
            run([.snapRight, .snapRight, .snapRight, .snapRight], from: floating, screens: screens)
                == [
                    .setFrame(at(.right)), .setFrame(at(.left, rightScreen)), .setFrame(restoredThere),
                    .setFrame(at(.right, rightScreen)),
                ])
        // Back: left half of the external screen → right half of the built-in one; then,
        // with no floating frame known, the left half.
        #expect(
            run([.snapLeft, .snapLeft], from: at(.left, rightScreen), screens: screens)
                == [.setFrame(at(.right)), .setFrame(at(.left))])
        // A quarter keeps its row across screens; at the end of the chain, nothing happens.
        #expect(
            run([.snapRight, .maximize, .snapRight], from: floating, screens: screens).last
                == .setFrame(at(.topLeft, rightScreen)))
        #expect(
            run([.snapLeft, .snapLeft], from: floating, screens: screens).last
                == .none(reason: "already left, no screen on the left"))
    }

    @Test func neighbourScreensFollowTheArrangement() {
        let all = [screen, rightScreen, leftScreen, aboveScreen]
        #expect(LayoutEngine.neighbour(of: screen, toLeft: false, among: all) == rightScreen)
        #expect(LayoutEngine.neighbour(of: screen, toLeft: true, among: all) == leftScreen)
        #expect(LayoutEngine.neighbour(of: rightScreen, toLeft: true, among: all) == screen)
        // A screen stacked above is nobody's left/right neighbour… unless its centre is offset.
        #expect(LayoutEngine.neighbour(of: screen, toLeft: true, among: [screen, aboveScreen]) == nil)
        // Built-in centre 900, above-screen centre 960: the above screen is "to the right",
        // but a screen that overlaps vertically wins.
        #expect(
            LayoutEngine.neighbour(of: screen, toLeft: false, among: [screen, aboveScreen, rightScreen]) == rightScreen)
    }

    @Test func moveToScreenKeepsThePlacementOrTheRelativePosition() {
        let screens = [screen, rightScreen]
        #expect(
            run([.snapLeft, .moveToScreenRight], from: floating, screens: screens).last
                == .setFrame(at(.left, rightScreen)))
        let moved = run([.moveToScreenRight], from: floating, screens: screens).last
        // 640×480 at 200/1161 of the free width → same fraction on the external screen.
        #expect(
            moved == .setFrame(LayoutEngine.carry(floating, from: screen.visibleFrame, to: rightScreen.visibleFrame)))
        #expect(
            run([.moveToScreenLeft], from: floating, screens: screens).last == .none(reason: "no screen on the left"))
        // Too big for the target: shrunk to fit, inside it.
        let big = Rect(x: 0, y: 40, width: 1801, height: 1069)
        let carried = LayoutEngine.carry(
            big, from: screen.visibleFrame, to: Rect(x: 1801, y: 0, width: 1280, height: 800))
        #expect(carried == Rect(x: 1801, y: 0, width: 1280, height: 800))
    }

    @Test func aWindowCenteredInItsTargetCountsAsPlaced() {
        // An app that refuses the half size ends centered in it: ↑ must still give the quarter.
        var engine = LayoutEngine()
        _ = engine.handle(.snapLeft, window: window(floating), screens: [screen])
        let constrained = LayoutEngine.centered(width: 700, height: 600, in: at(.left))
        #expect(engine.placement(of: window(constrained), on: screen) == .left)
        #expect(engine.handle(.maximize, window: window(constrained), screens: [screen]) == .setFrame(at(.topLeft)))
    }
}

// MARK: - Drag zones

@Suite struct SnapZoneTests {
    let zones = SnapZones()
    let screens = [screen, rightScreen]

    private func at(_ x: Double, _ y: Double, current: SnapZones.Zone? = nil) -> Placement? {
        zones.zone(atX: x, y: y, screens: screens, current: current)?.placement
    }

    @Test func edgesAndCornersOfTheBuiltInScreen() {
        // Built-in screen frame: 0…1801 × 0…1169.
        #expect(at(0, 600) == .left)
        #expect(at(0, 30) == .topLeft)
        #expect(at(0, 1160) == .bottomLeft)
        #expect(at(900, 0) == .maximized)
        #expect(at(40, 0) == .topLeft)
        #expect(at(1790, 0) == .topRight)
        #expect(at(900, 1168) == nil)  // bottom edge: only its ends
        #expect(at(30, 1168) == .bottomLeft)
        #expect(at(900, 600) == nil)
        #expect(at(10, 600) == nil)  // 10 pt from the edge: not yet
    }

    @Test func theZoneGivesAFrameInTheVisibleArea() {
        let zone = zones.zone(atX: 0, y: 600, screens: [screen], current: nil)
        #expect(zone?.frame == Placement.left.frame(in: screen.visibleFrame))
        let external = zones.zone(atX: 3720, y: 500, screens: screens, current: nil)
        #expect(external?.placement == .right && external?.screen == rightScreen)
    }

    @Test func hysteresisKeepsTheZoneUntilTheCursorLeavesTheEdge() {
        let left = zones.zone(atX: 0, y: 600, screens: [screen], current: nil)
        #expect(left?.placement == .left)
        // 25 pt away: entering would need 6, keeping allows 40.
        #expect(at(25, 600, current: left) == .left)
        #expect(at(60, 600, current: left) == nil)
        // Sliding down the same edge turns the half into the bottom quarter.
        #expect(at(20, 1150, current: left) == .bottomLeft)
    }
}

@Suite struct DragLayoutTests {
    @Test func droppingAFloatingWindowRemembersItsFrame() {
        var engine = LayoutEngine()
        #expect(engine.dragStarted(window(floating), cursorX: 400, cursorY: 160, screens: [screen]) == nil)
        // The user dragged it to the left edge: its frame moved meanwhile.
        let moved = Rect(x: 5, y: 300, width: 640, height: 480)
        #expect(engine.drop(window(moved), at: .left, on: screen, screens: [screen]) == .setFrame(at(.left)))
        // ⌃↓ … ⌃→ on the left half gives back the frame from before the drag.
        #expect(engine.handle(.snapRight, window: window(at(.left)), screens: [screen]) == .setFrame(floating))
    }

    @Test func draggingAPlacedWindowGivesItsSizeBack() {
        var engine = LayoutEngine()
        _ = engine.handle(.snapLeft, window: window(floating), screens: [screen])
        // Grabbed at 3/4 of the half's width (x = 675 of 900), in the title bar.
        let restored = engine.dragStarted(window(at(.left)), cursorX: 675, cursorY: 50, screens: [screen])
        #expect(restored == Rect(x: 675 - 480, y: 40, width: 640, height: 480))
        // Dropped elsewhere: floating; the next ⌃← remembers *that* frame.
        #expect(engine.handle(.snapLeft, window: window(restored!), screens: [screen]) == .setFrame(at(.left)))
        #expect(engine.restoreFrames[WindowID(1)] == restored)
    }
}
