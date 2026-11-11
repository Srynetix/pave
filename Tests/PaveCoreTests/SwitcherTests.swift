// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import PaveCore

private func win(_ id: UInt32, _ app: String, pid: PID? = nil, title: String = "", state: WindowState = .normal)
    -> WindowSnapshot
{
    WindowSnapshot(
        id: WindowID(id), pid: pid ?? PID(id), appName: app, title: title,
        frame: Rect(x: 0, y: 0, width: 100, height: 100), state: state, subrole: "AXStandardWindow")
}

/// MRU order: Slack (current), Brave, Brave (2nd window), Obsidian, Finder (minimized).
private let mru = [
    win(1, "Slack"), win(2, "Brave Browser", pid: 20, title: "Devis Acme"),
    win(3, "Brave Browser", pid: 20, title: "Docs"),
    win(4, "Obsidian", title: "Réunion équipe"), win(5, "Finder", state: .minimized),
]

private func ids(_ s: SwitcherSession) -> [UInt32] { s.entries.map(\.id.rawValue) }

@Suite struct SwitcherOpeningTests {
    @Test func ctrlTabSelectsThePreviousWindow() {
        let s = SwitcherSession(windows: mru)
        #expect(ids(s) == [1, 2, 3, 4, 5])
        #expect(s.selected?.id == WindowID(2))
        #expect(s.commit() == .focus(WindowID(2), mruRank: 1))
    }

    @Test func ctrlShiftTabSelectsTheLeastRecent() {
        #expect(SwitcherSession(windows: mru, backwards: true).selected?.id == WindowID(5))
    }

    @Test func aSingleOrNoWindow() {
        #expect(SwitcherSession(windows: [win(1, "Slack")]).selection == 0)
        let empty = SwitcherSession(windows: [])
        #expect(empty.selection == nil)
        #expect(empty.commit() == .dismiss)
    }

    @Test func minimizedAndHiddenWindowsAreListedWithTheirState() {
        let s = SwitcherSession(windows: mru + [win(6, "Mail", state: .hidden)])
        #expect(s.entries.last?.state == .hidden)
        #expect(s.entries.first { $0.id == WindowID(5) }?.state == .minimized)
    }

    @Test func scopeWorkspaceListsOnlyTheActiveOne() {
        let workspaces = [WindowID(2): 2, WindowID(4): 2]  // others: active (1)
        let scoped = SwitcherSession(
            windows: mru, options: .init(scope: .workspace, activeWorkspace: 1, workspaceOf: workspaces))
        #expect(ids(scoped) == [1, 3, 5])
        // MRU ranks still refer to the full order (S5 logs).
        #expect(scoped.selected?.mruRank == 2)

        let all = SwitcherSession(
            windows: mru, options: .init(scope: .all, activeWorkspace: 1, workspaceOf: workspaces))
        #expect(ids(all) == [1, 2, 3, 4, 5])
        // Workspaces off (no active workspace): everything, whatever the scope.
        #expect(
            ids(SwitcherSession(windows: mru, options: .init(scope: .workspace, workspaceOf: workspaces))).count == 5)
    }

    @Test func sameAppModeListsOneApp() {
        let s = SwitcherSession(windows: mru, options: .init(onlyApp: 20))
        #expect(ids(s) == [2, 3])
        #expect(s.selected?.id == WindowID(3))
    }
}

@Suite struct SwitcherNavigationTests {
    @Test func nextAndPreviousWrapAround() {
        var s = SwitcherSession(windows: mru)
        s.next()
        s.next()
        s.next()
        #expect(s.selected?.id == WindowID(5))
        s.next()
        #expect(s.selected?.id == WindowID(1))
        s.previous()
        #expect(s.selected?.id == WindowID(5))
    }

    @Test func verticalMovesByRowsAndStopsAtTheEdges() {
        var s = SwitcherSession(windows: mru)  // selection 1, 3 columns: row 0 = [1 2 3], row 1 = [4 5]
        s.vertical(1, columns: 3)
        #expect(s.selected?.id == WindowID(5))
        s.vertical(1, columns: 3)
        #expect(s.selected?.id == WindowID(5))
        s.vertical(-1, columns: 3)
        #expect(s.selected?.id == WindowID(2))
    }
}

@Suite struct SwitcherSearchTests {
    @Test func typingOnlyWorksInSearchMode() {
        var s = SwitcherSession(windows: mru)
        s.type("ob")
        #expect(s.query.isEmpty)
        s.enterSearch()
        s.type("ob")
        #expect(s.mode == .search)
        #expect(ids(s) == [4])
        #expect(s.commit() == .focus(WindowID(4), mruRank: 3))
    }

    @Test func ranksAppPrefixThenWordStartThenSubsequence() {
        var s = SwitcherSession(windows: [
            win(1, "Notes", title: "Brave new world"),  // word start in the title
            win(2, "Zed", title: "brw.txt"),  // word start
            win(3, "Brave Browser"),  // app prefix
            win(4, "Obsidian", title: "b r w"),  // subsequence only
        ])
        s.enterSearch()
        s.type("br")
        // 3 (app prefix), then 1 and 2 (word start, MRU order), then 4 (subsequence).
        #expect(ids(s) == [3, 1, 2, 4])
        #expect(s.selected?.id == WindowID(3))
        s.type("w")  // "brw": a word start only in 2, a subsequence in the others
        #expect(ids(s) == [2, 1, 3, 4])
    }

    @Test func searchIgnoresCaseAndAccents() {
        var s = SwitcherSession(windows: mru)
        s.enterSearch()
        s.type("REUNION EQ")
        #expect(ids(s) == [4])
        s.deleteBackward()
        s.deleteBackward()
        s.deleteBackward()
        #expect(s.query == "REUNION")
    }

    @Test func noMatchMeansNothingToCommit() {
        var s = SwitcherSession(windows: mru)
        s.enterSearch()
        s.type("xyz")
        #expect(s.entries.isEmpty)
        #expect(s.selection == nil)
        #expect(s.commit() == .dismiss)
        s.deleteBackward()
        s.deleteBackward()
        s.deleteBackward()
        #expect(ids(s).count == 5)
    }
}

@Suite struct SwitcherActionTests {
    @Test func closeRemovesTheEntryAndSelectsTheNextOne() {
        var s = SwitcherSession(windows: mru)  // selected: 2
        #expect(s.closeSelected() == .close(WindowID(2)))
        #expect(ids(s) == [1, 3, 4, 5])
        #expect(s.selected?.id == WindowID(3))
        s.next()
        s.next()  // 5, the last one
        #expect(s.closeSelected() == .close(WindowID(5)))
        #expect(s.selected?.id == WindowID(4))
    }

    @Test func quitRemovesEveryWindowOfTheApp() {
        var s = SwitcherSession(windows: mru)  // selected: 2 (Brave, pid 20)
        #expect(s.quitSelectedApp() == .quit(20))
        #expect(ids(s) == [1, 4, 5])
        #expect(s.selected?.id == WindowID(4))
    }

    @Test func closingTheLastWindowLeavesAnEmptySession() {
        var s = SwitcherSession(windows: [win(1, "Slack")])
        _ = s.closeSelected()
        #expect(s.selection == nil)
        #expect(s.closeSelected() == nil)
        #expect(s.commit() == .dismiss)
    }

    @Test func registryUpdatesKeepTheOrderAndTheSelection() {
        var s = SwitcherSession(windows: mru)
        s.next()  // 3
        // Meanwhile: window 1 closed, 4 retitled, 9 opened, and the MRU order changed.
        var four = mru[3]
        four.title = "Autre"
        s.update(windows: [win(9, "TextEdit"), mru[4], mru[2], four, mru[1]])
        #expect(ids(s) == [2, 3, 4, 5, 9])
        #expect(s.selected?.id == WindowID(3))
        #expect(s.entries[2].title == "Autre")
    }

    @Test func theScreenScopeListsTheWindowsOfTheScreenInUse() {
        let ws = [win(1, "A"), win(2, "B"), win(3, "C")]
        let options = SwitcherSession.Options(scope: .screen, onScreen: [WindowID(1), WindowID(3)])
        #expect(SwitcherSession(windows: ws, options: options).all.map(\.id) == [WindowID(1), WindowID(3)])
    }
}
