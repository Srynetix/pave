// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import ApplicationServices
import PaveCore

/// Reads and presses the menu the Dock shows for an app, where the app's quick
/// actions are. No API gives that menu: the Dock is asked to open it on its
/// item (`AXShowMenu`), it is read, then closed, under a `DockMenuMask` that
/// hides it (ADR 0004).
///
/// The Accessibility calls run on their own queue: the Dock may be slow to
/// answer, and no AX call runs on the main thread. Entries may hold window
/// titles: only counts are logged.
@MainActor
final class DockMenuReader {
    /// How long the Dock gets to fill its menu (it takes ~40 ms).
    nonisolated static let menuTimeout: TimeInterval = 0.3
    private let queue = DispatchQueue(label: "pave.dock-menu")
    private let mask = DockMenuMask()

    /// The Dock menu of the app with this bundle ID, empty if it has no item.
    func read(bundleID: String) async -> [DockMenuEntry] {
        await masked(bundleID) { Self.withMenu(of: bundleID) { Self.entries(of: $0) } ?? [] }
    }

    /// Presses the entry at `path` (its title, then those of its submenus):
    /// the menu is opened again, as the app only answers its own menu's items.
    func press(bundleID: String, path: [String]) async {
        let pressed = await masked(bundleID) {
            Self.withMenu(of: bundleID) { menu -> Bool in
                guard let entry = Self.find(path, in: menu) else { return false }
                return AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success
            } ?? false
        }
        Log.info("taskbar: quick action of \(bundleID) \(pressed ? "pressed" : "FAILED")")
    }

    /// Runs `body` on the queue, the band the Dock's menu opens in covered.
    private func masked<T: Sendable>(_ bundleID: String, _ body: @escaping @Sendable () -> T) async -> T {
        let item = await onQueue { Self.itemFrame(bundleID) }
        let screens = NSScreen.screens.map(Screens.axFrame)
        let covered =
            if let item, let band = DockMenu.maskedBand(item: item, screens: screens) {
                await mask.cover(band)
            } else { false }
        let result = await onQueue(body)
        if covered { await mask.uncover() }
        return result
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    // MARK: - Accessibility

    private nonisolated static func itemFrame(_ bundleID: String) -> Rect? {
        dockItem(bundleID)?.frame
    }

    private nonisolated static func withMenu<T>(of bundleID: String, _ body: (AXUIElement) -> T) -> T? {
        guard let item = dockItem(bundleID), AXUIElementPerformAction(item, "AXShowMenu" as CFString) == .success
        else { return nil }
        let deadline = Date().addingTimeInterval(menuTimeout)
        var menu: AXUIElement?
        while menu == nil, Date() < deadline {
            menu = children(item).first { role($0) == kAXMenuRole && !children($0).isEmpty }
            if menu == nil { usleep(10_000) }
        }
        guard let menu else { return nil }
        let result = body(menu)
        // Pressing an entry closes the menu; reading leaves it open.
        if children(item).contains(where: { role($0) == kAXMenuRole }) {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
        return result
    }

    private nonisolated static func dockItem(_ bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let dock = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(dock, 0.5)
        for list in children(dock) {
            for item in children(list) {
                if let url = attribute(item, kAXURLAttribute) as? URL, Bundle(url: url)?.bundleIdentifier == bundleID {
                    return item
                }
            }
        }
        return nil
    }

    private nonisolated static func entries(of menu: AXUIElement) -> [DockMenuEntry] {
        children(menu).filter { role($0) == kAXMenuItemRole }.map { item in
            let mark = attribute(item, kAXMenuItemMarkCharAttribute) as? String
            let submenu = children(item).first { role($0) == kAXMenuRole }
            return DockMenuEntry(
                attribute(item, kAXTitleAttribute) as? String ?? "",
                isEnabled: (attribute(item, kAXEnabledAttribute) as? Bool) ?? true,
                isChecked: !(mark ?? "").isEmpty,
                children: submenu.map(entries(of:)) ?? [])
        }
    }

    private nonisolated static func find(_ path: [String], in menu: AXUIElement) -> AXUIElement? {
        guard let title = path.first,
            let item = children(menu).first(where: { attribute($0, kAXTitleAttribute) as? String == title })
        else { return nil }
        if path.count == 1 { return item }
        return children(item).first { role($0) == kAXMenuRole }.flatMap { find(Array(path.dropFirst()), in: $0) }
    }

    private nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private nonisolated static func role(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
