// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore
import PaveIPC
import PaveMac
import ServiceManagement

/// Window arrangements: the picker (⌃⇧A), the menu, `pave arrangement`.
extension AppDelegate {
    // MARK: - Arrangements

    func openArrangementPicker(_ id: Int) {
        let screens = Screens.all()
        guard started,
            let screen = registry.focusedWindow.flatMap({ LayoutEngine.screen(for: $0.frame, among: screens) })
                ?? Screens.underMouse(among: screens) ?? screens.first
        else { return hotkeys?.endSession(id) ?? () }
        arrangementPicker.open(
            id: id, area: screen.visibleFrame,
            rows: arrangements.arrangements.map { a in
                .init(
                    name: a.name,
                    detail: String(localized: "\(a.places.count) windows · \(Set(a.places.map(\.app)).count) apps"))
            })
    }

    func restoreArrangement(_ name: String) {
        guard let summary = arrangements.restore(name) else { return }
        Log.info("arrangement: \(summary)")  // its name is the user's: never logged
        refresh()
    }

    /// Asks for a name (the current one proposed when it exists), then saves.
    func saveArrangementFromUI() {
        let previous = NSWorkspace.shared.frontmostApplication
        let alert = NSAlert()
        alert.messageText = String(localized: "Save the window arrangement")
        alert.informativeText = String(
            localized:
                "Each window's app, workspace and place are saved, never its title. The same name replaces the arrangement."
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Name, like Code or Meeting")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate()
        let response = alert.runModal()
        defer { if let previous, previous != NSRunningApplication.current { previous.activate() } }
        guard response == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard Arrangement.isValidName(name) else {
            return showAlert(
                String(localized: "Arrangement not saved"),
                String(localized: "A name of letters, digits, spaces, - or _"))
        }
        if arrangements.save(name) == nil {
            showAlert(String(localized: "Arrangement not saved"), String(localized: "No window to save."))
        }
    }

    @objc func saveArrangementFromMenu() { saveArrangementFromUI() }

    @objc func restoreArrangementFromMenu(_ sender: NSMenuItem) {
        restoreArrangement(sender.representedObject as? String ?? "")
    }

    @objc func deleteArrangementFromMenu(_ sender: NSMenuItem) {
        _ = arrangements.delete(sender.representedObject as? String ?? "")
    }

    func rebuildArrangementsMenu() {
        arrangementsMenu.removeAllItems()
        let list = arrangements.arrangements
        for a in list {
            let item = NSMenuItem(title: a.name, action: #selector(restoreArrangementFromMenu(_:)), keyEquivalent: "")
            item.representedObject = a.name
            arrangementsMenu.addItem(item)
        }
        if !list.isEmpty { arrangementsMenu.addItem(.separator()) }
        arrangementsMenu.addItem(
            NSMenuItem(
                title: String(localized: "Save Current Arrangement…"), action: #selector(saveArrangementFromMenu),
                keyEquivalent: ""))
        if !list.isEmpty {
            let delete = NSMenuItem(title: String(localized: "Delete"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for a in list {
                let item = NSMenuItem(
                    title: a.name, action: #selector(deleteArrangementFromMenu(_:)), keyEquivalent: "")
                item.representedObject = a.name
                sub.addItem(item)
            }
            delete.submenu = sub
            arrangementsMenu.addItem(delete)
        }
    }

    /// `pave arrangement …`.
    func arrangementCommand(_ args: [String]) -> (Bool, String) {
        guard started else { return (false, "Pavé is not started (Accessibility)") }
        let command: ArrangementCommand
        switch ArrangementCommand.parse(args) {
        case .failure(let usage): return (false, usage.description)
        case .success(let parsed): command = parsed
        }
        switch command {
        case .list:
            let list = arrangements.arrangements
            if list.isEmpty { return (true, "no arrangement yet: pave arrangement save NAME") }
            return (
                true,
                list.map { "\($0.name): \($0.places.count) window(s) of \(Set($0.places.map(\.app)).count) app(s)" }
                    .joined(separator: "\n")
            )
        case .save(let name):
            guard let summary = arrangements.save(name) else { return (false, "no window to save") }
            return (true, "\(name): \(summary)")
        case .restore(let name):
            guard let summary = arrangements.restore(name) else { return (false, "no arrangement named \"\(name)\"") }
            return (true, "\(name): \(summary)")
        case .delete(let name):
            return arrangements.delete(name) ? (true, "\(name) deleted") : (false, "no arrangement named \"\(name)\"")
        }
    }
}
