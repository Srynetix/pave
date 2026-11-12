// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// An entry's context menu: open, close, move or pin to a workspace, quit, pin.
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
        if let everywhere = everywhereItem(windows) { menu.addItem(everywhere) }
        if let pin = pinMenu(item, name: name) { menu.addItem(pin) }
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

    /// "Pin to Workspace ▸": where new windows open.
    /// - "All <App> Windows": 1…9 / Not Pinned, the app rule `workspace = N`;
    /// - "This Window ▸ 1…9": a title rule `"*<its title>" = N`, then its rule
    ///   in Settings, where the pattern is shortened ("*Work");
    /// - "Pin by Window Title…": the app's rule in Settings.
    func pinMenu(_ item: TaskbarItem, name: String) -> NSMenuItem? {
        guard workspacesEnabled(), !item.app.hasPrefix("pid:") else { return nil }
        let app = item.app
        let rule = appRule(app)
        let names = workspaceNames()
        func label(_ n: Int) -> String { n <= names.count && !names[n - 1].isEmpty ? "\(n)  \(names[n - 1])" : "\(n)" }
        func entry(_ menu: NSMenu, _ title: String, checked: Bool, _ action: @escaping () -> Void) {
            let entry = ClosureMenuItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""), handler: action)
            if checked {
                entry.state = .on
                entry.action = nil  // disabled: already so
            }
            menu.addItem(entry)
        }
        let submenu = NSMenu()
        submenu.addItem(.sectionHeader(title: String(localized: "All \(name) Windows")))
        for n in Workspaces.range {
            entry(submenu, label(n), checked: rule.workspace == n) { [weak self] in self?.pinToWorkspace(app, n) }
        }
        entry(submenu, String(localized: "Not Pinned"), checked: rule.workspace == nil) { [weak self] in
            self?.pinToWorkspace(app, nil)
        }
        submenu.addItem(.separator())
        // One window: its title (the entry of a window, or an app with one).
        let windows = item.windowIDs.compactMap { registry.store.windows[$0] }
        if windows.count == 1, !windows[0].title.isEmpty {
            let pattern = "*" + windows[0].title
            let this = NSMenu()
            for n in Workspaces.range {
                entry(this, label(n), checked: rule.titles[pattern] == .workspace(n)) { [weak self] in
                    self?.pinWindowTitle(app, pattern, .workspace(n))
                }
            }
            this.addItem(.separator())
            entry(this, String(localized: "All Workspaces"), checked: rule.titles[pattern] == .everywhere) {
                [weak self] in self?.pinWindowTitle(app, pattern, .everywhere)
            }
            let thisItem = NSMenuItem(title: String(localized: "This Window"), action: nil, keyEquivalent: "")
            thisItem.submenu = this
            submenu.addItem(thisItem)
        }
        let count = rule.titles.count + rule.profiles.count
        entry(
            submenu,
            count == 0 ? String(localized: "Pin by Window Title…") : String(localized: "Title Rules (\(count))…"),
            checked: false
        ) { [weak self] in self?.editAppRule(app) }
        let pin = NSMenuItem(title: String(localized: "Pin to Workspace"), action: nil, keyEquivalent: "")
        pin.submenu = submenu
        return pin
    }

    /// "Show on All Workspaces", checked when it is: one window, never parked,
    /// it follows the workspace shown on its screen. Until it closes; a title
    /// rule `"all"` covers the windows to come.
    func everywhereItem(_ windows: [WindowSnapshot]) -> NSMenuItem? {
        guard workspacesEnabled(), windows.count == 1 else { return nil }
        let id = windows[0].id
        let on = isEverywhere(id)
        let item = ClosureMenuItem(
            NSMenuItem(title: String(localized: "Show on All Workspaces"), action: nil, keyEquivalent: "")
        ) { [weak self] in self?.setEverywhere(id, !on) }
        item.state = on ? .on : .off
        return item
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
