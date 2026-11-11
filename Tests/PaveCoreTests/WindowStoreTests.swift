// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import PaveCore

private func win(
    _ id: UInt32, pid: PID = 1, title: String = "w", x: Double = 0, state: WindowState = .normal
) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(id), pid: pid, appName: "App\(pid)", title: title,
        frame: Rect(x: x, y: 0, width: 100, height: 100), state: state, subrole: "AXStandardWindow")
}

@Suite struct WindowStoreTests {
    /// Regression (H1 campaign, Safari): ⌃← right after ⌃↓ remembered the
    /// stale pre-restore frame as the "original" one.
    @Test func frameReadBackAfterAMoveIsUsedImmediately() {
        var store = WindowStore()
        store.apply(AppSnapshot(pid: 1, windows: [win(1)], focusedWindow: nil), isFrontmost: false)
        let moved = Rect(x: 900, y: 40, width: 900, height: 1068)
        #expect(
            store.updateFrame(WindowID(1), to: moved) == [.frameChanged(WindowID(1), from: win(1).frame, to: moved)])
        #expect(store.windows[WindowID(1)]?.frame == moved)
        #expect(store.updateFrame(WindowID(1), to: moved).isEmpty)
        #expect(store.updateFrame(WindowID(99), to: moved).isEmpty)
    }

    @Test func createsWindowsOnFirstSnapshot() {
        var store = WindowStore()
        let changes = store.apply(
            AppSnapshot(pid: 1, windows: [win(2), win(1)], focusedWindow: nil), isFrontmost: false)
        #expect(changes == [.created(win(1)), .created(win(2))])
        #expect(store.windows.count == 2)
    }

    @Test func reportsDestroyedWindowsOfThatAppOnly() {
        var store = WindowStore()
        store.apply(AppSnapshot(pid: 1, windows: [win(1), win(2)], focusedWindow: nil), isFrontmost: false)
        store.apply(AppSnapshot(pid: 2, windows: [win(10, pid: 2)], focusedWindow: nil), isFrontmost: false)

        let changes = store.apply(AppSnapshot(pid: 1, windows: [win(2)], focusedWindow: nil), isFrontmost: false)
        #expect(changes == [.destroyed(win(1))])
        #expect(Set(store.windows.keys) == [WindowID(2), WindowID(10)])
        #expect(!store.mru.contains(WindowID(1)))
    }

    @Test func reportsFrameTitleAndStateChanges() {
        var store = WindowStore()
        store.apply(AppSnapshot(pid: 1, windows: [win(1)], focusedWindow: nil), isFrontmost: false)
        let changes = store.apply(
            AppSnapshot(pid: 1, windows: [win(1, title: "b", x: 50, state: .minimized)], focusedWindow: nil),
            isFrontmost: false)
        #expect(
            changes == [
                .frameChanged(WindowID(1), from: win(1).frame, to: win(1, x: 50).frame),
                .retitled(WindowID(1), from: "w", to: "b"),
                .stateChanged(WindowID(1), from: .normal, to: .minimized),
            ])
    }

    @Test func noChangeForIdenticalSnapshot() {
        var store = WindowStore()
        let snap = AppSnapshot(pid: 1, windows: [win(1)], focusedWindow: WindowID(1))
        store.apply(snap, isFrontmost: true)
        #expect(store.apply(snap, isFrontmost: true).isEmpty)
    }

    @Test func focusBumpsMRUOnlyWhenAppIsFrontmost() {
        var store = WindowStore()
        store.apply(AppSnapshot(pid: 1, windows: [win(1)], focusedWindow: nil), isFrontmost: false)
        store.apply(AppSnapshot(pid: 2, windows: [win(2, pid: 2)], focusedWindow: nil), isFrontmost: false)
        #expect(store.mru == [WindowID(1), WindowID(2)])

        // Background app changing its own focused window: not the user's focus.
        store.apply(AppSnapshot(pid: 2, windows: [win(2, pid: 2)], focusedWindow: WindowID(2)), isFrontmost: false)
        #expect(store.mru == [WindowID(1), WindowID(2)])

        let changes = store.apply(
            AppSnapshot(pid: 2, windows: [win(2, pid: 2)], focusedWindow: WindowID(2)), isFrontmost: true)
        #expect(changes == [.focused(WindowID(2))])
        #expect(store.mru == [WindowID(2), WindowID(1)])
    }

    @Test func removeAppDestroysAllItsWindows() {
        var store = WindowStore()
        store.apply(AppSnapshot(pid: 1, windows: [win(1), win(2)], focusedWindow: nil), isFrontmost: false)
        store.apply(AppSnapshot(pid: 2, windows: [win(3, pid: 2)], focusedWindow: nil), isFrontmost: false)
        #expect(store.removeApp(1).count == 2)
        #expect(store.orderedWindows.map(\.id) == [WindowID(3)])
    }
}

@Suite struct WindowChangeDescriptionTests {
    @Test func titlesAreRedactedByDefault() {
        let change = WindowChange.created(win(1, title: "Devis client confidentiel"))
        #expect(!change.description.contains("Devis"))
        #expect(change.description.contains("<title:25>"))
        #expect(change.describe(showTitles: true).contains("\"Devis client confidentiel\""))
    }

    /// Regression: a minimized TextEdit window came back as
    /// "AXDialog" and vanished from the taskbar.
    @Test func minimizedWindowKeepsItsRole() {
        var store = WindowStore()
        store.apply(AppSnapshot(pid: 1, windows: [win(1)], focusedWindow: nil), isFrontmost: true)
        var minimized = win(1, state: .minimized)
        minimized.subrole = "AXDialog"
        store.apply(AppSnapshot(pid: 1, windows: [minimized], focusedWindow: nil), isFrontmost: true)
        #expect(store.windows[WindowID(1)]?.subrole == "AXStandardWindow")
        #expect(store.windows[WindowID(1)]?.state == .minimized)
    }
}

@Suite struct WindowStoreRetentionTests {
    private func window(_ id: UInt32) -> WindowSnapshot {
        WindowSnapshot(
            id: WindowID(id), pid: 7, appName: "App", title: "", frame: Rect(x: 0, y: 0, width: 100, height: 100),
            state: .normal, subrole: "AXStandardWindow")
    }

    @Test func aMissingWindowTheCallerKeepsIsNotDestroyed() {
        var store = WindowStore()
        store.apply(AppSnapshot(pid: 7, windows: [window(1), window(2)], focusedWindow: nil), isFrontmost: false)
        // Full-screen Space on: AX lists window 2 only; 1 is on another Space.
        let changes = store.apply(
            AppSnapshot(pid: 7, windows: [window(2)], focusedWindow: nil), isFrontmost: false,
            keep: { $0.id == WindowID(1) })
        #expect(changes.isEmpty)
        #expect(store.windows[WindowID(1)] != nil)
        // Back on its Space: no "created", it never left.
        let back = store.apply(
            AppSnapshot(pid: 7, windows: [window(1), window(2)], focusedWindow: nil), isFrontmost: false)
        #expect(back.isEmpty)
    }

    @Test func aMissingWindowNobodyKeepsIsDestroyed() {
        var store = WindowStore()
        store.apply(AppSnapshot(pid: 7, windows: [window(1)], focusedWindow: nil), isFrontmost: false)
        let changes = store.apply(
            AppSnapshot(pid: 7, windows: [], focusedWindow: nil), isFrontmost: false, keep: { _ in false })
        #expect(changes == [.destroyed(window(1))])
    }
}
