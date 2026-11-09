import Foundation
import Testing
@testable import PaveCore

private let screen = Screen(
    frame: Rect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrame: Rect(x: 0, y: 40, width: 1800, height: 1069))

private func win(_ id: UInt32, x: Double = 100, state: WindowState = .normal) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(id), pid: 1, appName: "App", title: "",
        frame: Rect(x: x, y: 100, width: 600, height: 400), state: state, subrole: "AXStandardWindow")
}

private func hidden(_ w: WindowSnapshot) -> Rect { Workspaces.hiddenFrame(for: w.frame, on: screen) }

@Suite struct WorkspacesTests {
    @Test func newWindowsLiveInActiveWorkspace() {
        var ws = Workspaces()
        ws.adopt(WindowID(1))
        #expect(ws.workspace(of: WindowID(1)) == 1)
        #expect(ws.workspace(of: WindowID(99)) == 1)  // unknown → active
    }

    @Test func switchHidesOutgoingAndFocusesMostRecentIncoming() {
        var ws = Workspaces()
        let a = win(1), b = win(2, x: 300)
        let actions = ws.switchTo(2, windows: [a, b], screen: screen)
        #expect(actions == [.setFrame(a.id, hidden(a)), .setFrame(b.id, hidden(b))])
        #expect(ws.active == 2)
        #expect(ws.isHidden(a.id) && ws.isHidden(b.id))

        // A window opened on workspace 2, then back to 1: the 2 is hidden, 1 restored,
        // focus goes to the most recently used window of workspace 1.
        let c = win(3, x: 500)
        ws.adopt(c.id)
        let parkedA = WindowSnapshot(id: a.id, pid: 1, appName: "App", title: "", frame: hidden(a), state: .normal, subrole: "AXStandardWindow")
        let parkedB = WindowSnapshot(id: b.id, pid: 1, appName: "App", title: "", frame: hidden(b), state: .normal, subrole: "AXStandardWindow")
        let back = ws.switchTo(1, windows: [c, parkedB, parkedA], screen: screen)
        #expect(back == [.setFrame(c.id, hidden(c)), .setFrame(b.id, b.frame), .setFrame(a.id, a.frame), .focus(b.id)])
        #expect(!ws.isHidden(a.id) && ws.isHidden(c.id))
    }

    @Test func switchToSameOrInvalidWorkspaceDoesNothing() {
        var ws = Workspaces()
        #expect(ws.switchTo(1, windows: [win(1)], screen: screen).isEmpty)
        #expect(ws.switchTo(10, windows: [win(1)], screen: screen).isEmpty)
        #expect(ws.switchTo(0, windows: [win(1)], screen: screen).isEmpty)
    }

    @Test func minimizedWindowsStayInTheirWorkspaceWithoutParking() {
        var ws = Workspaces()
        let m = win(1, state: .minimized)
        #expect(ws.switchTo(2, windows: [m], screen: screen).isEmpty)
        #expect(ws.workspace(of: m.id) == 1)
        #expect(!ws.isHidden(m.id))
    }

    @Test func moveParksWindowAndFocusesNextOne() {
        var ws = Workspaces()
        let a = win(1), b = win(2)
        let actions = ws.move(a, to: 3, windows: [a, b], screen: screen)
        #expect(actions == [.setFrame(a.id, hidden(a)), .focus(b.id)])
        #expect(ws.workspace(of: a.id) == 3)
        // Switching to 3 brings it back.
        let switched = ws.switchTo(3, windows: [b, a], screen: screen)
        #expect(switched.contains(.setFrame(a.id, a.frame)))
        #expect(switched.last == .focus(a.id))
    }

    @Test func focusingAHiddenWindowFollowsItToItsWorkspace() {
        var ws = Workspaces()
        let a = win(1), b = win(2)
        _ = ws.move(a, to: 2, windows: [a, b], screen: screen)
        let actions = ws.focused(a.id, windows: [a, b], screen: screen)
        #expect(ws.active == 2)
        #expect(actions.contains(.setFrame(a.id, a.frame)))
        #expect(actions.contains(.setFrame(b.id, hidden(b))))
        #expect(!actions.contains { if case .focus = $0 { true } else { false } })
    }

    @Test func restoreAllBringsEverythingBack() {
        var ws = Workspaces()
        let a = win(1), b = win(2)
        _ = ws.switchTo(2, windows: [a, b], screen: screen)
        let actions = ws.restoreAll()
        #expect(actions == [.setFrame(a.id, a.frame), .setFrame(b.id, b.frame)])
        #expect(ws.hiddenCount == 0)
        #expect(ws.workspace(of: a.id) == ws.active)
        #expect(ws.active == 1)
    }

    @Test func survivesJSONRoundTrip() throws {
        var ws = Workspaces()
        _ = ws.switchTo(2, windows: [win(1), win(2)], screen: screen)
        let data = try JSONEncoder().encode(ws)
        #expect(try JSONDecoder().decode(Workspaces.self, from: data) == ws)
    }

    @Test func parkingSpotLeavesOnePointOnScreen() {
        let spot = Workspaces.hiddenFrame(for: win(1).frame, on: screen)
        #expect(spot.intersectionArea(with: screen.frame) == 1)
    }

    /// 2026-11-09: Slack opened by its app rule on hidden workspace 4 and got
    /// the focus in the same batch. Park (adopt) then show (focus): the
    /// window ends where it was opened, and only if the park is applied first.
    @Test func appRuleThenFocusParksThenShows() {
        var ws = Workspaces()
        _ = ws.screensChanged([screen], windows: [])
        let slack = win(1)
        let parked = ws.adopt(slack, screens: [screen], preferred: 4)
        #expect(parked.count == 1 && ws.isHidden(slack.id))
        let shown = ws.focused(slack.id, focusedScreen: screen, screens: [screen], windows: [slack])
        #expect(shown == [.setFrame(slack.id, slack.frame)])
        #expect(ws.active == 4 && !ws.isHidden(slack.id))
    }

    /// A frame saved almost off the screen (1 pt on it) comes back inside.
    @Test func showBringsBackAFrameSavedOffScreen() {
        var ws = Workspaces()
        _ = ws.screensChanged([screen], windows: [])
        let lost = WindowSnapshot(
            id: WindowID(1), pid: 1, appName: "App", title: "",
            frame: Rect(x: 1799, y: 40, width: 1800, height: 1089), state: .normal, subrole: "AXStandardWindow")
        _ = ws.adopt(lost, screens: [screen], preferred: 4)
        let actions = ws.switchTo(4, focusedScreen: screen, screens: [screen], windows: [lost])
        guard case .setFrame(_, let frame) = actions.first else { Issue.record("no frame"); return }
        #expect(frame.x == 0 && frame.maxX <= screen.frame.maxX)
    }
}

@Suite struct ProfileResolvedTests {
    private let screen = Screen(
        frame: Rect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: Rect(x: 0, y: 40, width: 1800, height: 1069))
    private func win(_ id: UInt32, x: Double = 100) -> WindowSnapshot {
        WindowSnapshot(
            id: WindowID(id), pid: 1, appName: "App", title: "",
            frame: Rect(x: x, y: 100, width: 600, height: 400), state: .normal, subrole: "AXStandardWindow")
    }

    @Test func inFrontTheWorkspaceFollows() {
        var ws = Workspaces()
        _ = ws.screensChanged([screen], windows: [])
        let other = win(1, x: 300), brave = win(2)
        _ = ws.adopt(other, screens: [screen])
        _ = ws.adopt(brave, screens: [screen])
        let actions = ws.ruleResolved(brave, to: 3, follow: true, focusedScreen: screen, screens: [screen], windows: [brave, other])
        #expect(ws.active == 3 && ws.workspace(of: brave.id) == 3)
        #expect(!ws.isHidden(brave.id) && ws.isHidden(other.id))
        // Parked, then shown back where it was: the last move puts it in place.
        #expect(actions.last(where: { if case .setFrame(brave.id, _) = $0 { true } else { false } }) == .setFrame(brave.id, brave.frame))
    }

    @Test func inTheBackItIsSentAway() {
        var ws = Workspaces()
        _ = ws.screensChanged([screen], windows: [])
        let other = win(1, x: 300), brave = win(2)
        _ = ws.adopt(other, screens: [screen])
        _ = ws.adopt(brave, screens: [screen])
        _ = ws.ruleResolved(brave, to: 3, follow: false, focusedScreen: screen, screens: [screen], windows: [other, brave])
        #expect(ws.active == 1 && ws.workspace(of: brave.id) == 3 && ws.isHidden(brave.id))
    }
}

@Suite struct OutOfSightTests {
    @Test func minimizedWindowsAreSeenOnTheirWorkspaceOnly() {
        let screen = Screen(
            frame: Rect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: Rect(x: 0, y: 40, width: 1800, height: 1069))
        var ws = Workspaces()
        _ = ws.screensChanged([screen], windows: [])
        let minimized = WindowSnapshot(
            id: WindowID(1), pid: 1, appName: "App", title: "",
            frame: Rect(x: 100, y: 100, width: 600, height: 400), state: .minimized, subrole: "AXDialog")
        _ = ws.adopt(minimized, screens: [screen])
        #expect(!ws.isOutOfSight(minimized.id))
        _ = ws.switchTo(2, focusedScreen: screen, screens: [screen], windows: [minimized])
        #expect(!ws.isHidden(minimized.id) && ws.isOutOfSight(minimized.id))
        _ = ws.switchTo(1, focusedScreen: screen, screens: [screen], windows: [minimized])
        #expect(!ws.isOutOfSight(minimized.id))
    }
}
