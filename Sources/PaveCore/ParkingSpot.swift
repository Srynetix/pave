// SPDX-License-Identifier: MIT OR Apache-2.0
/// Where to park a window of an inactive workspace.
///
/// macOS refuses a window entirely off screen: a parked window keeps a 1 pt
/// column on its screen's edge and extends outwards. macOS then pulls it up
/// (by up to its whole height) to keep its title bar on a screen. A corner is
/// safe only if that band, from the top of the screen down to its bottom plus
/// the window height, touches no other screen: otherwise the parked window
/// shows on the neighbour (up to 1799×858 pt, measured). Only bottom
/// corners are candidates: nothing goes above the menu bar.
public enum ParkingSpot {
    public enum Corner: String, Sendable { case bottomRight, bottomLeft }

    /// Parking frame (same size) at `corner` of `screen`.
    public static func frame(for window: Rect, at corner: Corner, of screen: Screen) -> Rect {
        let s = screen.frame
        let x = corner == .bottomRight ? s.maxX - 1 : s.x - window.width + 1
        return Rect(x: x, y: s.maxY - 1, width: window.width, height: window.height)
    }

    /// True when no other screen sees the window parked at `corner` of `screen`.
    public static func isSafe(_ corner: Corner, of screen: Screen, among screens: [Screen], windowSize: Rect) -> Bool {
        let s = screen.frame
        let x = corner == .bottomRight ? s.maxX : s.x - windowSize.width
        let band = Rect(x: x, y: s.y, width: windowSize.width, height: s.height + windowSize.height)
        return !screens.contains { $0.frame != s && $0.frame.intersectionArea(with: band) > 0 }
    }

    /// Safe parking frame for `window`, preferably on `screen`, else on another
    /// screen. nil when no corner of any screen is safe (W1 KO: caller decides).
    public static func park(_ window: Rect, on screen: Screen, among screens: [Screen]) -> Rect? {
        let all = screens.isEmpty ? [screen] : screens
        for candidate in [screen] + all.filter({ $0.frame != screen.frame }) {
            for corner in [Corner.bottomRight, .bottomLeft]
            where isSafe(corner, of: candidate, among: all, windowSize: window) {
                return frame(for: window, at: corner, of: candidate)
            }
        }
        return nil
    }
}
