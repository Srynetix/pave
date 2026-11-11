// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// NSScreen (bottom-left origin) → PaveCore.Screen in AX coordinates
/// (top-left origin of the primary screen, y growing downwards).
@MainActor
public enum Screens {
    /// Height of Pavé's taskbar at the bottom of each screen (0 when off): the
    /// usable area stops above it, for every placement.
    public static var taskbarHeight: Double = 0
    /// The Dock is hidden for good (taskbar with hide-dock): the space macOS
    /// sometimes keeps reserved for it is usable all the same.
    public static var ignoresDockReserve = false

    /// The usable area of `screen` (AppKit coordinates), before the taskbar:
    /// visibleFrame, or down to the screen's edges when the Dock is ignored
    /// (the menu bar stays out).
    public static func usableArea(of screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame
        guard ignoresDockReserve else { return v }
        let f = screen.frame
        return NSRect(x: f.minX, y: f.minY, width: f.width, height: v.maxY - f.minY)
    }

    /// Display names, in the order of `all()`.
    public static func names() -> [String] { NSScreen.screens.map(\.localizedName) }

    /// The index in `all()` of the screen `selector` designates: its index,
    /// "builtin", part of its name (case-insensitive), or its UUID.
    public static func index(matching selector: String) -> Int? {
        let screens = NSScreen.screens
        if let n = Int(selector) { return n >= 0 && n < screens.count ? n : nil }
        let wanted = selector.lowercased()
        if ["builtin", "built-in", "integre", "intégré"].contains(wanted) {
            return screens.firstIndex { screen in
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                return number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
            }
        }
        if let i = screens.firstIndex(where: { id(of: $0).lowercased() == wanted }) { return i }
        return screens.firstIndex { $0.localizedName.lowercased().contains(wanted) }
    }

    public static func all() -> [Screen] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        func ax(_ r: NSRect) -> Rect {
            Rect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        let menuBars = menuBarBottoms()
        return NSScreen.screens.map {
            let frame = ax($0.frame)
            var visible = ax(usableArea(of: $0))
            // A secondary screen's menu bar ("separate Spaces") is not always
            // left out of visibleFrame (seen on an LG 2560×1440): take it out.
            if let bottom = menuBars.first(where: { $0.x >= frame.x && $0.x < frame.maxX && abs($0.y - frame.y) < 1 })?
                .bottom,
                bottom > visible.y
            {
                visible.height -= bottom - visible.y
                visible.y = bottom
            }
            visible.height -= taskbarHeight
            return Screen(frame: frame, visibleFrame: visible, id: id(of: $0))
        }
    }

    /// Menu bars on screen (Window Server, main menu level), cached for a
    /// moment: `all()` is called on every drag event.
    private static var menuBarCache: (bars: [(x: Double, y: Double, bottom: Double)], at: Date)?

    private static func menuBarBottoms() -> [(x: Double, y: Double, bottom: Double)] {
        if let cache = menuBarCache, Date().timeIntervalSince(cache.at) < 2 { return cache.bars }
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let bars: [(x: Double, y: Double, bottom: Double)] = list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == level,
                (info[kCGWindowOwnerName as String] as? String) == "Window Server",
                let dict = info[kCGWindowBounds as String] as? NSDictionary,
                let r = CGRect(dictionaryRepresentation: dict as CFDictionary), r.height < 60
            else { return nil }
            return (Double(r.minX), Double(r.minY), Double(r.maxY))
        }
        menuBarCache = (bars, Date())
        return bars
    }

    /// Display UUID: stable across launches and re-plugs (the display ID is not).
    public static func id(of screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
            let text = CFUUIDCreateString(nil, uuid) as String?
        else { return screen.localizedName }
        return text
    }

    /// Name and built-in flag of the screen with this UUID (zone layouts are
    /// looked up by UUID, "builtin" or part of the name).
    public static func identity(of id: String) -> (name: String, isBuiltIn: Bool)? {
        guard let screen = NSScreen.screens.first(where: { Self.id(of: $0) == id }) else { return nil }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return (screen.localizedName, number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false)
    }

    /// The screen under the mouse pointer.
    public static func underMouse(among screens: [Screen]) -> Screen? {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return screens.first { $0.frame.contains(x: p.x, y: primaryHeight - p.y) }
    }

    /// The frame of an NSScreen in AX coordinates.
    public static func axFrame(_ screen: NSScreen) -> Rect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let r = screen.frame
        return Rect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// AX rect (top-left origin) → AppKit rect (bottom-left origin), for Pavé's own windows.
    public static func appKit(_ r: Rect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.x, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
