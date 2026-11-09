import PaveCore
import Testing
@testable import PaveIPC

@Suite struct SubcommandTests {
    @Test func tiling() throws {
        #expect(try TilingCommand.parse([]).get() == .toggle)
        #expect(try TilingCommand.parse(["on"]).get() == .on)
        #expect(try TilingCommand.parse(["focus", "left"]).get() == .focus(.left))
        #expect(try TilingCommand.parse(["move", "down"]).get() == .move(.down))
        for bad in [["focus"], ["focus", "nowhere"], ["on", "now"], ["dance"]] {
            #expect(throws: UsageError.self) { try TilingCommand.parse(bad).get() }
        }
    }

    @Test func zones() throws {
        #expect(try ZonesCommand.parse([]).get() == .report)
        #expect(try ZonesCommand.parse(["off"]).get() == .enable(false))
        #expect(try ZonesCommand.parse(["set", "LG", "thirds"]).get() == .set(screen: "LG", layout: "thirds"))
        #expect(try ZonesCommand.parse(["edit"]).get() == .edit(screen: nil, layout: nil))
        #expect(try ZonesCommand.parse(["edit", "builtin", "focus"]).get() == .edit(screen: "builtin", layout: "focus"))
        for bad in [["set", "LG"], ["edit", "a", "b", "c"], ["on", "x"], ["wat"]] {
            #expect(throws: UsageError.self) { try ZonesCommand.parse(bad).get() }
        }
    }

    @Test func arrangement() throws {
        #expect(try ArrangementCommand.parse([]).get() == .list)
        #expect(try ArrangementCommand.parse(["save", "Morning", "code"]).get() == .save("Morning code"))
        #expect(try ArrangementCommand.parse(["restore", "Code"]).get() == .restore("Code"))
        for bad in [["save"], ["save", "a/b"], ["restore"], ["delete"], ["list", "x"], ["rename", "x"]] {
            #expect(throws: UsageError.self) { try ArrangementCommand.parse(bad).get() }
        }
    }

    @Test func update() throws {
        #expect(try UpdateCommand.parse([]).get() == .check)
        #expect(try UpdateCommand.parse(["install"]).get() == .install)
        #expect(throws: UsageError.self) { try UpdateCommand.parse(["install", "now"]).get() }
    }
}
