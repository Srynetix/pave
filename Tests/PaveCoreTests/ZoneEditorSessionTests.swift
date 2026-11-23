// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import PaveCore

struct ZoneEditorSessionTests {
    private let coding = try! ZoneLayout(name: "Coding", zones: [.init(0, 0, 30, 100), .init(30, 0, 70, 100)])

    private func session(start: String?) -> ZoneEditorSession {
        ZoneEditorSession(
            entries: [.init(layout: coding, isMine: true)]
                + ZoneLayout.builtIn.map { .init(layout: $0, isMine: false) },
            start: start)
    }

    @Test func itOpensOnTheLayoutAskedForElseANewOne() {
        #expect(session(start: "Coding").current == .layout("Coding"))
        #expect(session(start: "focus").current == .layout("focus"))
        #expect(session(start: nil).current == .new)
        #expect(session(start: "gone").current == .new)
        #expect(session(start: nil).draft.zones == [.init(0, 0, 100, 100)])
    }

    @Test func switchingKeepsEachLayoutsChanges() {
        var s = session(start: "Coding")
        _ = s.draft.split(0, columns: true)
        s.open(.layout("halves"))
        #expect(s.draft.zones == ZoneLayout.builtIn.first { $0.name == "halves" }!.zones)
        _ = s.draft.split(0, columns: false)
        s.open(.layout("Coding"))
        #expect(s.draft.zones.count == 3)
        #expect(s.modified == [.layout("Coding"), .layout("halves")])
        s.open(.layout("nothing"))
        #expect(s.current == .layout("Coding"))
    }

    @Test func undoingBackToTheSavedZonesIsNoChange() {
        var s = session(start: "Coding")
        _ = s.draft.split(0, columns: true)
        s.draft.undo()
        #expect(s.modified.isEmpty)
    }

    @Test func onlyTheUsersLayoutsSaveUnderTheirName() throws {
        var s = session(start: "Coding")
        _ = s.draft.split(1, columns: true)
        #expect(try s.layoutToSave(copyName: nil).get().name == "Coding")
        s.open(.layout("focus"))
        #expect(s.layoutToSave(copyName: nil) == .failure(.needsName))
        s.open(.new)
        #expect(s.layoutToSave(copyName: nil) == .failure(.needsName))
    }

    @Test func aCopyNeedsAFreeValidName() throws {
        let s = session(start: "Coding")
        #expect(s.layoutToSave(copyName: "Coding") == .failure(.nameTaken))
        #expect(s.layoutToSave(copyName: "thirds") == .failure(.builtInName))
        #expect(s.layoutToSave(copyName: "a/b") == .failure(.invalidName))
        #expect(try s.layoutToSave(copyName: "Coding 2").get().zones == coding.zones)
    }

    @Test func aSavedCopyIsTheUsersAndItsSourceIsLeftAsSaved() throws {
        var s = session(start: "focus")
        _ = s.draft.split(1, columns: false)
        let copy = try s.layoutToSave(copyName: "Focus 2").get()
        s.saved(copy)
        #expect(s.current == .layout("Focus 2") && s.isMine)
        #expect(s.entries.last == .init(layout: copy, isMine: true))
        #expect(s.modified.isEmpty)
        s.open(.layout("focus"))
        #expect(s.draft.zones == ZoneLayout.builtIn[0].zones)
    }

    @Test func savingInPlaceReplacesTheEntry() throws {
        var s = session(start: "Coding")
        _ = s.draft.split(1, columns: true)
        let layout = try s.layoutToSave(copyName: nil).get()
        s.saved(layout)
        #expect(s.entries.first?.layout.zones.count == 3)
        #expect(s.entries.count == ZoneLayout.builtIn.count + 1)
        #expect(s.modified.isEmpty)
    }

    @Test func theOriginFollowsItsCopiesButNotOtherLayouts() throws {
        var s = session(start: "focus")
        #expect(s.isOrigin)
        s.saved(try s.layoutToSave(copyName: "Focus 2").get())
        #expect(s.origin == .layout("Focus 2") && s.isOrigin)
        s.open(.layout("Coding"))
        #expect(!s.isOrigin)
        s.saved(try s.layoutToSave(copyName: nil).get())
        #expect(s.origin == .layout("Focus 2"))
    }
}
