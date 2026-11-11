// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import PaveCore

private func place(_ app: String, _ index: Int, workspace: Int = 1) -> Arrangement.Place {
    .init(
        app: app, index: index, workspace: workspace, screen: "S",
        frame: Rect(x: Double(index) * 10, y: 0, width: 100, height: 100))
}

private func candidate(_ id: UInt32, _ app: String) -> Arrangement.Candidate { .init(id: WindowID(id), app: app) }

@Suite struct ArrangementTests {
    @Test func windowsTakeThePlacesOfTheirAppInCreationOrder() {
        let arrangement = Arrangement(
            name: "Code", places: [place("brave", 0), place("brave", 1, workspace: 2), place("prism", 0)])
        // IDs grow with creation: #12 is Brave's first window, whatever order they come in.
        let match = arrangement.match([candidate(40, "brave"), candidate(12, "brave"), candidate(7, "prism")])
        #expect(match.placed.map(\.window) == [WindowID(12), WindowID(40), WindowID(7)])
        #expect(match.placed[1].place.workspace == 2)
        #expect(match.waiting.isEmpty && match.appsToLaunch.isEmpty)
    }

    @Test func missingWindowsWaitAndAbsentAppsAreLaunched() {
        let arrangement = Arrangement(name: "Code", places: [place("brave", 0), place("brave", 1), place("slack", 0)])
        let match = arrangement.match([candidate(5, "brave")])
        #expect(match.placed.map(\.window) == [WindowID(5)])
        #expect(match.waiting == [place("brave", 1), place("slack", 0)])
        // Brave runs (its second window cannot be opened for it); Slack does not.
        #expect(match.appsToLaunch == ["slack"])
    }

    @Test func extraWindowsAreLeftAlone() {
        let arrangement = Arrangement(name: "Code", places: [place("brave", 0)])
        #expect(
            arrangement.match([candidate(1, "brave"), candidate(2, "brave")]).placed.map(\.window) == [WindowID(1)])
    }

    @Test func indicesRankEachAppsWindows() {
        let ranks = Arrangement.indices(of: [candidate(9, "a"), candidate(3, "a"), candidate(4, "b")])
        #expect(ranks == [WindowID(3): 0, WindowID(9): 1, WindowID(4): 0])
    }

    @Test func arrangementsHoldNoTitleAndRoundTrip() throws {
        let arrangement = Arrangement(name: "Réunion", places: [place("brave", 0)])
        #expect(Arrangement.isValidName("Réunion") && !Arrangement.isValidName("a/b") && !Arrangement.isValidName(""))
        let mirror = Mirror(reflecting: arrangement.places[0]).children.compactMap(\.label)
        #expect(!mirror.contains("title"))
        #expect(mirror == ["app", "index", "workspace", "screen", "frame", "zones"])
    }
}
