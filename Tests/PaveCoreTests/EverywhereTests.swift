// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import Testing

@testable import PaveCore

private let a = Screen(
    frame: Rect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: Rect(x: 0, y: 40, width: 1800, height: 1089),
    id: "A")
private let b = Screen(
    frame: Rect(x: -2560, y: 0, width: 2560, height: 1440),
    visibleFrame: Rect(x: -2560, y: 31, width: 2560, height: 1409), id: "B")
private let screens = [a, b]

private func win(_ id: UInt32, on screen: Screen, state: WindowState = .normal) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(id), pid: 1, appName: "App", title: "",
        frame: Rect(x: screen.visibleFrame.x + 100, y: 100, width: 600, height: 400), state: state,
        subrole: "AXStandardWindow")
}

private func moved(_ actions: [Workspaces.Action]) -> Set<WindowID> {
    Set(actions.compactMap { if case .setFrame(let id, _) = $0 { id } else { nil } })
}

/// Two screens showing 1 (A) and 2 (B); window 1 on A, window 9 (a Picture
/// in Picture) on A, shown everywhere.
private func started() -> (Workspaces, WindowSnapshot, WindowSnapshot) {
    var ws = Workspaces()
    let w1 = win(1, on: a)
    let pip = win(9, on: a)
    _ = ws.screensChanged(screens, windows: [])
    _ = ws.adopt(w1, screens: screens)
    _ = ws.adopt(pip, screens: screens)
    #expect(ws.setEverywhere(pip, true, screens: screens).isEmpty)
    return (ws, w1, pip)
}

@Suite struct EverywhereTests {
    @Test func aSwitchLeavesItInPlaceAndItJoinsTheShownWorkspace() {
        var (ws, w1, pip) = started()
        let actions = ws.switchTo(3, focusedScreen: a, screens: screens, windows: [pip, w1])
        #expect(moved(actions) == [w1.id])
        #expect(!ws.isHidden(pip.id))
        #expect(ws.workspace(of: pip.id) == 3)
        #expect(!ws.isOutOfSight(pip.id))
        // Back to 1: the window of 1 comes back, the Picture in Picture follows.
        let back = ws.switchTo(1, focusedScreen: a, screens: screens, windows: [pip, w1])
        #expect(moved(back) == [w1.id])
        #expect(ws.workspace(of: pip.id) == 1)
    }

    @Test func itNeverTakesTheFocusOnASwitch() {
        var (ws, _, pip) = started()
        let actions = ws.switchTo(3, focusedScreen: a, screens: screens, windows: [pip])
        #expect(!actions.contains(.focus(pip.id)))
    }

    @Test func aSwitchOnTheOtherScreenLeavesItAlone() {
        var (ws, _, pip) = started()
        _ = ws.switchTo(4, focusedScreen: b, screens: screens, windows: [pip])
        #expect(ws.workspace(of: pip.id) == 1)
    }

    @Test func focusingItSwitchesNothing() {
        var (ws, w1, pip) = started()
        _ = ws.switchTo(3, focusedScreen: a, screens: screens, windows: [pip, w1])
        #expect(ws.focused(pip.id, focusedScreen: a, screens: screens, windows: [pip, w1]).isEmpty)
        #expect(ws.active == 3)
    }

    @Test func showingAWorkspaceOnAnotherScreenLeavesItWhereItIs() {
        var (ws, _, pip) = started()
        let actions = ws.display(1, on: b, screens: screens, windows: [pip])
        #expect(!moved(actions).contains(pip.id))
        // Screen A now shows another workspace: the Picture in Picture is there.
        #expect(ws.workspace(of: pip.id) == ws.visible["A"])
    }

    @Test func turnedOffItStaysOnTheWorkspaceItIsOn() {
        var (ws, w1, pip) = started()
        _ = ws.switchTo(3, focusedScreen: a, screens: screens, windows: [pip, w1])
        #expect(ws.setEverywhere(pip, false, screens: screens).isEmpty)
        #expect(ws.workspace(of: pip.id) == 3)
        let actions = ws.switchTo(1, focusedScreen: a, screens: screens, windows: [pip, w1])
        #expect(moved(actions) == [w1.id, pip.id])
        #expect(ws.isHidden(pip.id))
    }

    @Test func aParkedWindowComesBack() {
        var ws = Workspaces()
        let w = win(1, on: a)
        _ = ws.screensChanged(screens, windows: [])
        _ = ws.adopt(w, screens: screens)
        _ = ws.switchTo(3, focusedScreen: a, screens: screens, windows: [w])
        #expect(ws.isHidden(w.id))
        #expect(ws.setEverywhere(w, true, screens: screens) == [.setFrame(w.id, w.frame)])
        #expect(!ws.isHidden(w.id))
        #expect(ws.workspace(of: w.id) == 3)
    }

    @Test func sendingItToAWorkspaceShowsItThereOnly() {
        var (ws, _, pip) = started()
        _ = ws.move(pip, to: 5, windows: [pip], screens: screens)
        #expect(!ws.isEverywhere(pip.id))
        #expect(ws.isHidden(pip.id))
    }

    @Test func itIsNeverParkedAsAStray() {
        var (ws, _, pip) = started()
        _ = ws.switchTo(3, focusedScreen: a, screens: screens, windows: [])
        #expect(ws.parkStray(pip, screens: screens).isEmpty)
    }

    @Test func closedItIsForgotten() {
        var (ws, _, pip) = started()
        ws.forget(pip.id)
        #expect(!ws.isEverywhere(pip.id))
    }

    @Test func aRegroupKeepsOnlyTheWindowsStillOpen() {
        var (ws, w1, pip) = started()
        _ = ws.restoreAll(screens: screens, windows: [pip, w1])
        #expect(ws.isEverywhere(pip.id))
        _ = ws.restoreAll(screens: screens, windows: [w1])
        #expect(!ws.isEverywhere(pip.id))
    }

    @Test func aPlannedRestartKeepsIt() throws {
        let (ws, _, pip) = started()
        let data = try JSONEncoder().encode(ws)
        let back = try JSONDecoder().decode(Workspaces.self, from: data)
        #expect(back == ws)
        #expect(back.isEverywhere(pip.id))
    }

    @Test func floatingStandardWindowsAreShownEverywhere() {
        #expect(Workspaces.showsEverywhere(subrole: "AXStandardWindow", level: 3))
        #expect(!Workspaces.showsEverywhere(subrole: "AXStandardWindow", level: 0))
        #expect(!Workspaces.showsEverywhere(subrole: "AXStandardWindow", level: 25))
        #expect(!Workspaces.showsEverywhere(subrole: "AXDialog", level: 3))
    }
}
