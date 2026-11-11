// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import PaveCore

// Arrangements measured on real screens (AX coordinates).
private let builtIn = Screen(
    frame: Rect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: Rect(x: 0, y: 40, width: 1800, height: 1089),
    id: "A")
private func lg(x: Double, y: Double) -> Screen {
    Screen(
        frame: Rect(x: x, y: y, width: 2560, height: 1440),
        visibleFrame: Rect(x: x, y: y + 31, width: 2560, height: 1409), id: "B")
}
private let lgLeft = lg(x: -2560, y: 0)  // the measured arrangement: left, 271 pt lower
private let lgAbove = lg(x: -380, y: -1440)
private let lgRight = lg(x: 1800, y: 0)

private let small = Rect(x: 0, y: 0, width: 656, height: 422)
private let big = Rect(x: 0, y: 0, width: 1800, height: 1089)

@Suite struct ParkingSpotTests {
    @Test(arguments: [small, big])
    func spikeArrangementHasTwoSafeCornersOutOfFour(window: Rect) {
        let screens = [builtIn, lgLeft]
        #expect(ParkingSpot.isSafe(.bottomRight, of: builtIn, among: screens, windowSize: window))
        #expect(!ParkingSpot.isSafe(.bottomLeft, of: builtIn, among: screens, windowSize: window))
        #expect(!ParkingSpot.isSafe(.bottomRight, of: lgLeft, among: screens, windowSize: window))
        #expect(ParkingSpot.isSafe(.bottomLeft, of: lgLeft, among: screens, windowSize: window))
    }

    @Test func parksOnTheWindowsOwnScreenWhenPossible() {
        let screens = [builtIn, lgLeft]
        #expect(ParkingSpot.park(small, on: builtIn, among: screens) == Rect(x: 1799, y: 1168, width: 656, height: 422))
        #expect(ParkingSpot.park(small, on: lgLeft, among: screens) == Rect(x: -3215, y: 1439, width: 656, height: 422))
    }

    @Test func screenAboveBlocksNothing() {
        let screens = [builtIn, lgAbove]
        #expect(ParkingSpot.isSafe(.bottomRight, of: builtIn, among: screens, windowSize: big))
        #expect(ParkingSpot.isSafe(.bottomRight, of: lgAbove, among: screens, windowSize: big))
    }

    @Test func screenOnTheRightSendsBuiltInWindowsLeft() {
        let screens = [builtIn, lgRight]
        #expect(!ParkingSpot.isSafe(.bottomRight, of: builtIn, among: screens, windowSize: small))
        #expect(ParkingSpot.park(small, on: builtIn, among: screens)?.x == -655)
        #expect(ParkingSpot.park(small, on: lgRight, among: screens)?.x == 4359)
    }

    @Test func middleScreenParksOnANeighbour() {
        let left = Screen(
            frame: Rect(x: -1800, y: 0, width: 1800, height: 1169), visibleFrame: builtIn.visibleFrame, id: "L")
        let screens = [builtIn, left, lgRight]
        #expect(!ParkingSpot.isSafe(.bottomRight, of: builtIn, among: screens, windowSize: small))
        #expect(!ParkingSpot.isSafe(.bottomLeft, of: builtIn, among: screens, windowSize: small))
        let spot = ParkingSpot.park(small, on: builtIn, among: screens)
        #expect(spot != nil)
        // Wherever it went, at most the 1 pt column shows, and on one screen only.
        let seen = screens.map { spot.map($0.frame.intersectionArea) ?? 0 }.filter { $0 > 0 }
        #expect(seen.count == 1 && seen[0] <= 1)
    }

    @Test func singleScreenMatchesTheM0Corner() {
        #expect(
            ParkingSpot.park(small, on: builtIn, among: [builtIn]) == Workspaces.hiddenFrame(for: small, on: builtIn))
    }
}
