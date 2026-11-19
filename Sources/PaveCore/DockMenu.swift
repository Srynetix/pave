// SPDX-License-Identifier: MIT OR Apache-2.0

/// An entry of the menu the Dock shows for an app, as Accessibility reads it.
/// Its title may be a window title: shown on screen, never logged.
public struct DockMenuEntry: Equatable, Sendable {
    public var title: String
    public var isEnabled: Bool
    /// A mark in front of it: the app's current window, a chosen option.
    public var isChecked: Bool
    public var children: [DockMenuEntry]

    public init(_ title: String, isEnabled: Bool = true, isChecked: Bool = false, children: [DockMenuEntry] = []) {
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.children = children
    }

    public static let separator = DockMenuEntry("")

    /// The Dock gives its separators as entries without a title.
    public var isSeparator: Bool { title.isEmpty && children.isEmpty }
}

/// The quick actions of an app ("New Window", "New Private Window"…): what the
/// app adds to its Dock menu. The Dock lays that menu out in sections:
///
///     [the app's windows]  [the app's own sections…]  [Options ▸]  [Show All Windows, Hide, Quit]
///
/// Only the sections in between are kept. Titles are localized, so the Dock's
/// own sections are recognized by their place, never by their text.
public enum DockMenu {
    public static func quickActions(_ entries: [DockMenuEntry], windowTitles: Set<String>) -> [DockMenuEntry] {
        var sections = split(entries)
        // A layout not seen before: better no quick action than one of the Dock's.
        guard sections.count >= 2, let options = sections[sections.count - 2].first,
            sections[sections.count - 2].count == 1, !options.children.isEmpty
        else { return [] }
        sections.removeLast(2)
        // The window list: the current window is checked, but windows on another
        // Space or parked by a workspace may not be; a known title tells too.
        if let first = sections.first, first.contains(where: { $0.isChecked || windowTitles.contains($0.title) }) {
            sections.removeFirst()
        }
        return Array(sections.joined(separator: [DockMenuEntry.separator]))
    }

    /// How far from the Dock's edge its menu may reach: wide enough for its
    /// longest window titles.
    public static let maskDepth: Double = 700

    /// The band of screen the Dock's menu for the item at `item` opens in: along
    /// the edge of its screen the Dock sits on. A hidden Dock keeps its items
    /// just outside the screen, so the nearest screen and edge are taken.
    public static func maskedBand(item: Rect, screens: [Rect], depth: Double = maskDepth) -> Rect? {
        let cx = item.x + item.width / 2
        let cy = item.y + item.height / 2
        func distance(_ s: Rect) -> Double {
            let dx = max(s.x - cx, 0, cx - s.maxX)
            let dy = max(s.y - cy, 0, cy - s.maxY)
            return dx * dx + dy * dy
        }
        guard let screen = screens.min(by: { distance($0) < distance($1) }) else { return nil }
        let d = min(depth, screen.width, screen.height)
        let edges: [(distance: Double, band: Rect)] = [
            (abs(cx - screen.x), Rect(x: screen.x, y: screen.y, width: d, height: screen.height)),
            (abs(screen.maxX - cx), Rect(x: screen.maxX - d, y: screen.y, width: d, height: screen.height)),
            (abs(cy - screen.y), Rect(x: screen.x, y: screen.y, width: screen.width, height: d)),
            (abs(screen.maxY - cy), Rect(x: screen.x, y: screen.maxY - d, width: screen.width, height: d)),
        ]
        return edges.min(by: { $0.distance < $1.distance })?.band
    }

    private static func split(_ entries: [DockMenuEntry]) -> [[DockMenuEntry]] {
        entries.split(whereSeparator: \.isSeparator).map(Array.init)
    }
}
