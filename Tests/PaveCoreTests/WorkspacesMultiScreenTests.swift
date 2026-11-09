import Foundation
import Testing
@testable import PaveCore

// A measured arrangement: LG on the left, primary built-in screen first.
private let a = Screen(
    frame: Rect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: Rect(x: 0, y: 40, width: 1800, height: 1089), id: "A")
private let b = Screen(
    frame: Rect(x: -2560, y: 0, width: 2560, height: 1440), visibleFrame: Rect(x: -2560, y: 31, width: 2560, height: 1409), id: "B")
private let screens = [a, b]

private func win(_ id: UInt32, on screen: Screen, state: WindowState = .normal) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(id), pid: 1, appName: "App", title: "",
        frame: Rect(x: screen.visibleFrame.x + 100, y: 100, width: 600, height: 400), state: state, subrole: "AXStandardWindow")
}

/// Start-up with two screens and windows 1 (on A) and 2 (on B) adopted.
private func started() -> (Workspaces, WindowSnapshot, WindowSnapshot) {
    var ws = Workspaces()
    let w1 = win(1, on: a), w2 = win(2, on: b)
    let started = ws.screensChanged(screens, windows: []) + ws.adopt(w1, screens: screens) + ws.adopt(w2, screens: screens)
    #expect(started.isEmpty)
    return (ws, w1, w2)
}

private func parked(_ w: WindowSnapshot, at frame: Rect) -> WindowSnapshot {
    var copy = w
    copy.frame = frame
    return copy
}

private func frames(_ actions: [Workspaces.Action]) -> [WindowID: Rect] {
    var result: [WindowID: Rect] = [:]
    for case .setFrame(let id, let r) in actions { result[id] = r }
    return result
}

@Suite struct WorkspacesMultiScreenTests {
    @Test func eachScreenShowsAWorkspaceAndWindowsJoinTheirScreens() {
        let (ws, w1, w2) = started()
        #expect(ws.visible == ["A": 1, "B": 2])
        #expect(ws.active == 1)
        #expect(ws.workspace(of: w1.id) == 1 && ws.workspace(of: w2.id) == 2)
        #expect(ws.visibleWorkspaces == [1, 2])
    }

    @Test func aPlannedRestartKeepsTheWorkspaces() {
        var (ws, w1, w2) = started()
        let w3 = win(3, on: b)
        _ = ws.adopt(w3, screens: screens)
        let parking = ws.switchTo(4, focusedScreen: b, screens: screens, windows: [w2, w3, w1])
        let now = frames(parking)
        var saved = ws
        // The next run: window 3 was closed meanwhile, window 5 opened on A.
        let w5 = win(5, on: a)
        let windows = [w1, parked(w2, at: now[w2.id]!), w5]
        let actions = saved.resume(screens: screens, windows: windows)
        #expect(actions.isEmpty)  // nothing moves: parked windows stay parked
        #expect(saved.visible == ["A": 1, "B": 4])
        #expect(saved.workspace(of: w2.id) == 2 && saved.isHidden(w2.id))
        #expect(saved.workspace(of: w5.id) == 1)
        #expect(saved.assignment[w3.id] == nil && !saved.isHidden(w3.id))
        // A window of a hidden workspace found on screen is parked.
        var again = ws
        let stray = again.resume(screens: screens, windows: [w1, w2])
        #expect(frames(stray).keys.contains(w2.id) && again.isHidden(w2.id))
    }

    @Test func aWorkspaceCanBeShownOnAnotherScreen() {
        var (ws, w1, w2) = started()
        // Hidden workspace 3 lives on A; shown on B instead.
        _ = ws.move(w1, to: 3, windows: [w1, w2], screens: screens)
        var actions = ws.display(3, on: b, screens: screens, windows: [w2, w1])
        #expect(ws.visible == ["A": 1, "B": 3] && ws.home[3] == "B")
        #expect(frames(actions)[w2.id] != nil)  // 2 parked
        #expect(frames(actions)[w1.id].map { b.frame.intersectionArea(with: $0) > 0 } == true)  // 1 carried onto B
        // Workspace 3, shown on B, moves to A: B shows its own workspace 2 again.
        let w1OnB = parked(w1, at: frames(actions)[w1.id]!)
        let w2Parked = parked(w2, at: frames(actions)[w2.id]!)
        actions = ws.display(3, on: a, screens: screens, windows: [w1OnB, w2Parked])
        #expect(ws.visible == ["A": 3, "B": 2] && ws.home[3] == "A")
        #expect(frames(actions)[w1.id].map { a.frame.intersectionArea(with: $0) > 0 } == true)
        #expect(frames(actions)[w2.id] == w2.frame)  // back from its parking spot
        #expect(ws.display(3, on: a, screens: screens, windows: [w1OnB]).allSatisfy { if case .setFrame = $0 { false } else { true } })
    }

    @Test func switchingOnOneScreenLeavesTheOtherAlone() {
        var (ws, w1, w2) = started()
        let actions = ws.switchTo(3, focusedScreen: b, screens: screens, windows: [w2, w1])
        // Window 2 parked at the LG's safe corner (bottom-left), window 1 untouched.
        #expect(frames(actions) == [w2.id: ParkingSpot.frame(for: w2.frame, at: .bottomLeft, of: b)])
        #expect(ws.visible == ["A": 1, "B": 3])
        #expect(ws.active == 3)
        #expect(ws.home[3] == "B")
    }

    @Test func aWorkspaceAlreadyShownOnlyGetsTheFocus() {
        var (ws, w1, w2) = started()
        let actions = ws.switchTo(2, focusedScreen: a, screens: screens, windows: [w1, w2])
        #expect(actions == [.focus(w2.id)])
        #expect(ws.active == 2)
        #expect(ws.visible == ["A": 1, "B": 2])
    }

    @Test func aWorkspaceComesBackOnItsHomeScreen() {
        var (ws, w1, w2) = started()
        _ = ws.switchTo(3, focusedScreen: b, screens: screens, windows: [w2, w1])
        let p2 = parked(w2, at: ParkingSpot.frame(for: w2.frame, at: .bottomLeft, of: b))
        // Win+2 typed while the focus is on A: 2 still comes back on B.
        let actions = ws.switchTo(2, focusedScreen: a, screens: screens, windows: [w1, p2])
        #expect(frames(actions) == [w2.id: w2.frame])
        #expect(ws.visible == ["A": 1, "B": 2])
    }

    @Test func sendingToAWorkspaceShownElsewhereMovesTheWindowThere() {
        var (ws, w1, w2) = started()
        let actions = ws.move(w1, to: 2, windows: [w1, w2], screens: screens)
        #expect(actions == [.setFrame(w1.id, LayoutEngine.carry(w1.frame, from: a.visibleFrame, to: b.visibleFrame))])
        #expect(ws.workspace(of: w1.id) == 2)
        #expect(!ws.isHidden(w1.id))
    }

    @Test func sendingToAHiddenWorkspaceParksAndFocusesTheNextWindow() {
        var (ws, w1, w2) = started()
        let w3 = win(3, on: a)
        _ = ws.adopt(w3, screens: screens)
        let actions = ws.move(w1, to: 5, windows: [w1, w3, w2], screens: screens)
        #expect(actions == [.setFrame(w1.id, ParkingSpot.frame(for: w1.frame, at: .bottomRight, of: a)), .focus(w3.id)])
        #expect(ws.home[5] == "A")
        let back = ws.switchTo(5, focusedScreen: b, screens: screens, windows: [w3, w2, w1])
        #expect(frames(back)[w1.id] == w1.frame)  // on A, its home, not on the focused B
        #expect(ws.visible["A"] == 5)
    }

    @Test func unpluggingKeepsTheLostScreensWindowsVisible() {
        var (ws, w1, w2) = started()
        // macOS moved window 2 onto A when B went away: it stays there, visible.
        let moved = parked(w2, at: Rect(x: 300, y: 200, width: 600, height: 400))
        let actions = ws.screensChanged([a], windows: [w1, moved])
        #expect(actions.isEmpty)
        #expect(ws.visible == ["A": 1])
        #expect(ws.workspace(of: w2.id) == 1 && !ws.isHidden(w2.id))
    }

    @Test func unpluggingReparksTheParkedWindowsMacOSMoved() {
        var (ws, w1, w2) = started()
        _ = ws.switchTo(3, focusedScreen: b, screens: screens, windows: [w2, w1])  // 2 parked on B
        // macOS dropped it on A's right edge, half visible.
        let dropped = parked(w2, at: Rect(x: 1500, y: 40, width: 600, height: 400))
        let actions = ws.screensChanged([a], windows: [w1, dropped])
        #expect(actions == [.setFrame(w2.id, ParkingSpot.frame(for: dropped.frame, at: .bottomRight, of: a))])
        #expect(ws.isHidden(w2.id) && ws.workspace(of: w2.id) == 2)
        #expect(ws.home[2] == "A")
    }

    @Test func aFrameSavedOnAScreenThatWentAwayIsCarriedOntoTheNewOne() {
        var (ws, w1, w2) = started()
        _ = ws.switchTo(3, focusedScreen: b, screens: screens, windows: [w2, w1])  // 2 parked, saved on B
        _ = ws.screensChanged([a], windows: [w1, w2])
        let back = ws.switchTo(2, focusedScreen: a, screens: [a], windows: [w1, w2])
        let frame = frames(back)[w2.id]
        #expect(frame.map { a.visibleFrame.intersectionArea(with: $0) == $0.area } == true)
    }

    @Test func aReturningScreenGetsItsWorkspacesBack() {
        var (ws, w1, w2) = started()
        let w4 = win(4, on: b)
        _ = ws.adopt(w4, screens: screens)
        _ = ws.move(w4, to: 6, windows: [w4, w1, w2], screens: screens)  // 6 lives on B, hidden
        // B goes away: macOS moves window 2 onto A, where it stays visible.
        let onA = parked(w2, at: Rect(x: 300, y: 200, width: 600, height: 400))
        _ = ws.screensChanged([a], windows: [w1, onA, w4])
        #expect(ws.workspace(of: w2.id) == 1 && ws.home[6] == "A")
        // B comes back and macOS puts window 2 back on it.
        _ = ws.screensChanged(screens, windows: [w1, w2, w4])
        #expect(ws.visible == ["A": 1, "B": 2])
        #expect(ws.workspace(of: w2.id) == 2)
        #expect(ws.home[2] == "B" && ws.home[6] == "B")
        #expect(ws.departed.isEmpty)
    }

    @Test func aNewScreenGetsAnEmptyWorkspace() {
        var (ws, w1, w2) = started()
        let c = Screen(frame: Rect(x: 1800, y: 0, width: 1920, height: 1080), visibleFrame: Rect(x: 1800, y: 25, width: 1920, height: 1055), id: "C")
        _ = ws.screensChanged(screens + [c], windows: [w1, w2])
        #expect(ws.visible["C"] == 3)
    }

    @Test func aWorkspaceShownElsewhereMeanwhileStaysThere() {
        var (ws, w1, w2) = started()
        let onA = parked(w2, at: Rect(x: 300, y: 200, width: 600, height: 400))
        _ = ws.screensChanged([a], windows: [w1, onA])
        _ = ws.switchTo(2, focusedScreen: a, screens: [a], windows: [w1, onA])  // the user shows 2 on A
        _ = ws.screensChanged(screens, windows: [w1, onA])
        #expect(ws.visible["A"] == 2)
        #expect(ws.visible["B"] != 2)
    }

    @Test func reparkLeavesWindowsAlreadyAtASafeCorner() {
        var (ws, w1, w2) = started()
        _ = ws.switchTo(3, focusedScreen: b, screens: screens, windows: [w2, w1])
        let atCorner = parked(w2, at: ParkingSpot.frame(for: w2.frame, at: .bottomLeft, of: b))
        #expect(ws.repark(screens, windows: [w1, atCorner]).isEmpty)
        let dropped = parked(w2, at: Rect(x: 1500, y: 40, width: 600, height: 400))
        #expect(ws.repark(screens, windows: [w1, dropped]).count == 1)
    }

    @Test func aWindowDraggedToTheOtherScreenJoinsItsWorkspace() {
        var (ws, w1, _) = started()
        let changed = ws.windowMoved(w1.id, to: Rect(x: -2000, y: 100, width: 600, height: 400), screens: screens)
        #expect(changed)
        #expect(ws.workspace(of: w1.id) == 2)
        let again = ws.windowMoved(w1.id, to: Rect(x: -1900, y: 100, width: 600, height: 400), screens: screens)
        #expect(!again)
    }

    @Test func parkedWindowsPulledUpByMacOSKeepTheirWorkspace() {
        var (ws, w1, w2) = started()
        _ = ws.switchTo(3, focusedScreen: b, screens: screens, windows: [w2, w1])
        let changed = ws.windowMoved(w2.id, to: Rect(x: -3159, y: 40, width: 600, height: 400), screens: screens)
        #expect(!changed)
        #expect(ws.workspace(of: w2.id) == 2)
    }

    @Test func appRuleSendsANewWindowToItsWorkspace() {
        var (ws, _, _) = started()
        let hiddenTarget = win(10, on: a)
        let parkedAtOnce = ws.adopt(hiddenTarget, screens: screens, preferred: 4)
        #expect(parkedAtOnce
            == [.setFrame(hiddenTarget.id, ParkingSpot.frame(for: hiddenTarget.frame, at: .bottomRight, of: a))])
        #expect(ws.workspace(of: hiddenTarget.id) == 4)
        let shownTarget = win(11, on: a)
        let actions = ws.adopt(shownTarget, screens: screens, preferred: 2)
        #expect(frames(actions)[shownTarget.id].map { b.frame.intersectionArea(with: $0) > 0 } == true)
        #expect(ws.workspace(of: shownTarget.id) == 2)
    }

    @Test func focusOnAnotherVisibleScreenOnlyChangesTheActiveWorkspace() {
        var (ws, w1, w2) = started()
        let actions = ws.focused(w2.id, focusedScreen: b, screens: screens, windows: [w2, w1])
        #expect(actions.isEmpty)
        #expect(ws.active == 2)
    }

    @Test func restoreAllRegroupsWindowsByScreen() {
        var (ws, w1, w2) = started()
        _ = ws.switchTo(3, focusedScreen: b, screens: screens, windows: [w2, w1])
        let actions = ws.restoreAll(screens: screens, windows: [w1, w2])
        #expect(actions == [.setFrame(w2.id, w2.frame)])
        #expect(ws.visible == ["A": 1, "B": 2])
        #expect(ws.workspace(of: w1.id) == 1 && ws.workspace(of: w2.id) == 2)
    }

    @Test func restoreAllCarriesFramesOfAScreenThatIsGone() {
        var (ws, w1, w2) = started()
        _ = ws.switchTo(3, focusedScreen: b, screens: screens, windows: [w2, w1])  // 2 saved on B
        let actions = ws.restoreAll(screens: [a], windows: [w1, w2])
        let frame = frames(actions)[w2.id]
        #expect(frame.map { a.visibleFrame.intersectionArea(with: $0) == $0.area } == true)
    }

    @Test func aWindowShownAgainOnAHiddenWorkspaceIsParked() {
        var (ws, w1, w2) = started()
        var hiddenApp = win(5, on: a, state: .hidden)  // ⌘H while on workspace 1
        _ = ws.adopt(hiddenApp, screens: screens)
        _ = ws.switchTo(4, focusedScreen: a, screens: screens, windows: [w1, hiddenApp, w2])
        #expect(!ws.isHidden(hiddenApp.id))  // hidden by its app: nothing to park then
        hiddenApp.state = .normal  // "Show All": it reappears on A, where 4 is shown
        let actions = ws.parkStray(hiddenApp, screens: screens)
        #expect(actions == [.setFrame(hiddenApp.id, ParkingSpot.frame(for: hiddenApp.frame, at: .bottomRight, of: a))])
        #expect(ws.workspace(of: hiddenApp.id) == 1 && ws.isHidden(hiddenApp.id))
        #expect(ws.parkStray(w2, screens: screens).isEmpty)  // its workspace is shown
    }

    @Test func readsStateFilesWrittenBeforeM4() throws {
        let old = #"{"active":2,"assignment":[7,2],"savedFrames":[7,{"x":1799,"y":1168,"width":600,"height":400}]}"#
        let ws = try JSONDecoder().decode(Workspaces.self, from: Data(old.utf8))
        #expect(ws.active == 2)
        #expect(ws.isHidden(WindowID(7)))
        #expect(ws.visible.isEmpty)
    }

    @Test func multiScreenStateSurvivesJSONRoundTrip() throws {
        var (ws, w1, w2) = started()
        _ = ws.switchTo(3, focusedScreen: b, screens: screens, windows: [w2, w1])
        let data = try JSONEncoder().encode(ws)
        #expect(try JSONDecoder().decode(Workspaces.self, from: data) == ws)
    }
}

@Suite struct WorkspaceIndicatorTests {
    @Test func eachBarListsItsScreensOccupiedWorkspaces() {
        var (ws, w1, w2) = started()
        let w3 = win(3, on: a)
        _ = ws.adopt(w3, screens: screens)
        _ = ws.move(w3, to: 5, windows: [w3, w1, w2], screens: screens)  // 5 lives on A, hidden
        _ = ws.switchTo(7, focusedScreen: b, screens: screens, windows: [w2, w1, w3])  // B shows an empty 7
        let windows = [w1, w2, w3]
        let onA = WorkspaceIndicator.items(for: "A", primaryID: "A", state: ws, windows: windows, names: ["Web", "", "", "", "Mail"])
        #expect(onA == [.init(number: 1, isVisible: true, name: "Web"), .init(number: 5, isVisible: false, name: "Mail")])
        let onB = WorkspaceIndicator.items(for: "B", primaryID: "A", state: ws, windows: windows)
        #expect(onB.map(\.number) == [2, 7])
        #expect(onB.map(\.isVisible) == [false, true])
    }

    @Test func switcherListsTheWorkspacesOfEveryScreen() {
        let (ws, w1, w2) = started()
        let w3 = win(3, on: a)
        let options = SwitcherSession.Options(
            scope: .workspace, activeWorkspace: ws.active, workspaceOf: [w1.id: 1, w2.id: 2, w3.id: 4],
            visibleWorkspaces: ws.visibleWorkspaces)
        let session = SwitcherSession(windows: [w1, w2, w3], options: options)
        #expect(session.all.map(\.id) == [w1.id, w2.id])
    }
}
