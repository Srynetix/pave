// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// An entry's context menu: open, close, move to a workspace, quit, pin.
extension TaskbarController {
    func contextMenu(_ item: TaskbarItem, event: NSEvent, view: NSView) {
        let menu = NSMenu()
        let windows = item.windowIDs.compactMap { registry.store.windows[$0] }
        let name = item.appName ?? appURL(item).map { FileManager.default.displayName(atPath: $0.path) } ?? item.app
        if windows.isEmpty {
            menu.addItem(
                ClosureMenuItem(NSMenuItem(title: String(localized: "Open \(name)"), action: nil, keyEquivalent: "")) {
                    [weak self] in
                    self?.launch(item)
                })
        }
        for window in windows.prefix(1) where windows.count == 1 {
            menu.addItem(
                ClosureMenuItem(NSMenuItem(title: String(localized: "Close Window"), action: nil, keyEquivalent: "")) {
                    [weak self] in
                    self?.registry.close(window) { ok in
                        Log.info("taskbar: close \(window.id) [\(window.appName)] \(ok ? "requested" : "FAILED")")
                    }
                })
        }
        if windows.count > 1 {
            menu.addItem(
                ClosureMenuItem(
                    NSMenuItem(
                        title: String(localized: "Close All Windows (\(windows.count))"), action: nil, keyEquivalent: ""
                    )
                ) { [weak self] in
                    for window in windows { self?.registry.close(window) }
                    Log.info("taskbar: close \(windows.count) window(s) of \(item.app)")
                })
        }
        if let move = workspaceMenu(windows) { menu.addItem(move) }
        if let pid = item.pid, let app = NSRunningApplication(processIdentifier: pid) {
            menu.addItem(
                ClosureMenuItem(NSMenuItem(title: String(localized: "Quit \(name)"), action: nil, keyEquivalent: "")) {
                    Log.info("taskbar: quit \(item.app) \(app.terminate() ? "requested" : "FAILED")")
                })
        }
        if !item.app.hasPrefix("pid:") {
            menu.addItem(.separator())
            let pinned = settings.pinned.contains(item.app)
            menu.addItem(
                ClosureMenuItem(
                    NSMenuItem(
                        title: pinned ? String(localized: "Unpin from Taskbar") : String(localized: "Pin to Taskbar"),
                        action: nil, keyEquivalent: "")
                ) {
                    [weak self] in
                    guard let self else { return }
                    var list = self.settings.pinned
                    if pinned { list.removeAll { $0 == item.app } } else { list.append(item.app) }
                    self.setPinned(list)
                })
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// "Move to Workspace ▸ 1…9": the item's windows; the workspace they are
    /// all on already is checked and disabled.
    func workspaceMenu(_ windows: [WindowSnapshot]) -> NSMenuItem? {
        guard !windows.isEmpty, let first = workspaceOf(windows[0].id) else { return nil }
        let current = windows.allSatisfy { workspaceOf($0.id) == first } ? first : nil
        let names = workspaceNames()
        let ids = windows.map(\.id)
        let submenu = NSMenu()
        for n in 1...9 {
            let label = n <= names.count && !names[n - 1].isEmpty ? "\(n)  \(names[n - 1])" : "\(n)"
            let entry = ClosureMenuItem(NSMenuItem(title: label, action: nil, keyEquivalent: "")) { [weak self] in
                self?.moveToWorkspace(ids, n)
            }
            if n == current {
                entry.state = .on
                entry.action = nil  // disabled: already there
            }
            submenu.addItem(entry)
        }
        let title =
            windows.count == 1
            ? String(localized: "Move to Workspace") : String(localized: "Move All Windows to Workspace")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}
