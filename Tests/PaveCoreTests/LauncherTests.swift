import Testing

@testable import PaveCore

@Suite struct LauncherTests {
    let apps = ["Slack", "Safari", "System Settings", "Brave Browser", "Préférences Réseau", "Calculator", "Notes"]
        .map { Launcher.App(name: $0, path: "/Applications/\($0).app") }

    private func names(_ query: String) -> [String] { Launcher.search(query, in: apps).map(\.name) }

    @Test func prefixThenWordThenLetters() {
        // Prefix matches first (alphabetical), then names merely containing an "s".
        #expect(Array(names("s").prefix(3)) == ["Safari", "Slack", "System Settings"])
        #expect(names("s").contains("Notes") && names("s").last != "Safari")
        #expect(names("set") == ["System Settings"])  // a word starts with it
        #expect(names("brw") == ["Brave Browser"])  // letters in order
        #expect(names("sl") == ["Slack"])
    }

    @Test func caseAccentsAndEmptyQuery() {
        #expect(names("PREF") == ["Préférences Réseau"])
        #expect(names("reseau") == ["Préférences Réseau"])
        #expect(names("").count == apps.count)
        #expect(names("").first == "Brave Browser")
        #expect(names("zzz").isEmpty)
    }
}
