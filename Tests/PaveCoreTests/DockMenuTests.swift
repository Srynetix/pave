// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import PaveCore

@Suite struct DockMenuTests {
    let options = DockMenuEntry("Options", children: [DockMenuEntry("Keep in Dock"), DockMenuEntry("Open at Login")])
    let standard = [DockMenuEntry("Show All Windows"), DockMenuEntry("Hide"), DockMenuEntry("Quit")]

    func menu(_ sections: [DockMenuEntry]...) -> [DockMenuEntry] {
        Array((sections + [[options], standard]).joined(separator: [DockMenuEntry.separator]))
    }

    @Test func keepsTheAppsOwnSectionsBetweenItsWindowsAndTheDocksOwn() {
        let profiles = [DockMenuEntry("Profiles", isEnabled: false), DockMenuEntry("Work"), DockMenuEntry("Perso")]
        let actions = [DockMenuEntry("New Window"), DockMenuEntry("New Private Window")]
        let entries = menu([DockMenuEntry("Inbox", isChecked: true)], profiles, actions)
        #expect(
            DockMenu.quickActions(entries, windowTitles: ["Inbox"]) == profiles + [DockMenuEntry.separator] + actions)
    }

    @Test func theWindowListIsRecognizedByItsMarkOrByATitle() {
        let actions = [DockMenuEntry("New Window")]
        // A window on another Space: unknown, but the current one is checked.
        let checked = menu([DockMenuEntry("Elsewhere"), DockMenuEntry("Here", isChecked: true)], actions)
        #expect(DockMenu.quickActions(checked, windowTitles: ["Here"]) == actions)
        // No window is current (the app is hidden): its titles tell.
        let known = menu([DockMenuEntry("Report")], actions)
        #expect(DockMenu.quickActions(known, windowTitles: ["Report"]) == actions)
    }

    @Test func anAppWithoutWindowsKeepsItsFirstSection() {
        let actions = [DockMenuEntry("New Window"), DockMenuEntry("New Private Window")]
        #expect(DockMenu.quickActions(menu(actions), windowTitles: []) == actions)
    }

    @Test func anAppWithoutQuickActionsHasNone() {
        #expect(DockMenu.quickActions(menu([DockMenuEntry("Inbox", isChecked: true)]), windowTitles: []).isEmpty)
        #expect(DockMenu.quickActions(menu(), windowTitles: []).isEmpty)
    }

    @Test func anUnknownLayoutGivesNoQuickAction() {
        // No "Options ▸" before the last section: nothing is trusted.
        let entries = [DockMenuEntry("New Window"), .separator, DockMenuEntry("Quit")]
        #expect(DockMenu.quickActions(entries, windowTitles: []).isEmpty)
        #expect(DockMenu.quickActions([], windowTitles: []).isEmpty)
    }

    @Test func emptySectionsAndRepeatedSeparatorsAreDropped() {
        let entries = [
            DockMenuEntry.separator, DockMenuEntry("New Window"), .separator, .separator, options, .separator,
            standard[0],
        ]
        #expect(DockMenu.quickActions(entries, windowTitles: []) == [DockMenuEntry("New Window")])
    }

    let screen = Rect(x: 0, y: 0, width: 1800, height: 1169)

    @Test func theMaskCoversTheBandAlongTheDocksEdge() {
        // A Dock hidden on the left keeps its items just outside the screen.
        let left = DockMenu.maskedBand(item: Rect(x: -20, y: 500, width: 16, height: 16), screens: [screen], depth: 700)
        #expect(left == Rect(x: 0, y: 0, width: 700, height: 1169))
        let bottom = DockMenu.maskedBand(
            item: Rect(x: 800, y: 1110, width: 48, height: 48), screens: [screen], depth: 700)
        #expect(bottom == Rect(x: 0, y: 469, width: 1800, height: 700))
        let right = DockMenu.maskedBand(
            item: Rect(x: 1790, y: 300, width: 48, height: 48), screens: [screen], depth: 700)
        #expect(right == Rect(x: 1100, y: 0, width: 700, height: 1169))
    }

    @Test func theMaskIsOnTheScreenOfTheDock() {
        let second = Rect(x: 1800, y: 0, width: 1440, height: 900)
        let band = DockMenu.maskedBand(
            item: Rect(x: 2400, y: 870, width: 48, height: 48), screens: [screen, second], depth: 2000)
        // On the second screen's bottom edge, no deeper than the screen.
        #expect(band == Rect(x: 1800, y: 0, width: 1440, height: 900))
        #expect(DockMenu.maskedBand(item: Rect(x: 0, y: 0, width: 1, height: 1), screens: []) == nil)
    }
}
