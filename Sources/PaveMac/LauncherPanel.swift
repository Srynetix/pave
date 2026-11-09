import AppKit
import PaveCore

/// The Start button's launcher: a search field
/// over the installed apps, typed into right away, ↑/↓ to choose, Return to
/// launch, Escape or a click elsewhere to close.
///
/// A non-activating panel that may become key: it gets the keyboard without
/// activating Pavé, so the app the user was in stays the "previous" one.
@MainActor
final class LauncherPanel: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let size = NSSize(width: 420, height: 360)
    static let rowHeight: CGFloat = 30

    private let panel: KeyablePanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private var apps: [Launcher.App] = []
    private var results: [Launcher.App] = []
    private var icons: [String: NSImage] = [:]
    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        super.init()
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        field.frame = NSRect(x: 12, y: Self.size.height - 44, width: Self.size.width - 24, height: 30)
        field.placeholderString = String(localized: "Search for an app")
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        field.focusRingType = .none
        background.addSubview(field)

        let column = NSTableColumn(identifier: .init("app"))
        // Full width: without it the column keeps its narrow default and names are cut.
        column.width = Self.size.width - 16 - 20
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        let scroll = NSScrollView(frame: NSRect(x: 8, y: 8, width: Self.size.width - 16, height: Self.size.height - 60))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        background.addSubview(scroll)
    }

    /// Opens above `anchor` (the Start button), with a fresh list of apps.
    func show(above anchor: NSView) {
        apps = Self.installedApps()
        field.stringValue = ""
        update()
        guard let window = anchor.window else { return }
        let origin = window.convertToScreen(anchor.convert(anchor.bounds, to: nil)).origin
        panel.setFrameOrigin(NSPoint(x: max(origin.x, window.frame.minX + 6), y: window.frame.maxY + 6))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func hide() { panel.orderOut(nil) }

    private func update() {
        results = Launcher.search(field.stringValue, in: apps)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.scrollRowToVisible(0)
    }

    private func launch(_ app: Launcher.App) {
        hide()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            // App names are not confidential; still, the path is enough.
            Log.info("launcher: open \(app.path) " + (error.map { "FAILED (\($0.localizedDescription))" } ?? "ok"))
        }
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0, table.clickedRow < results.count else { return }
        launch(results[table.clickedRow])
    }

    // MARK: Field

    func controlTextDidChange(_ obj: Notification) { update() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(0, table.selectedRow + step), results.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if table.selectedRow >= 0, table.selectedRow < results.count { launch(results[table.selectedRow]) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    // A click elsewhere: the panel loses the keyboard, and closes.
    func windowDidResignKey(_ notification: Notification) { hide() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = results[row]
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = .init("cell")
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.font = .systemFont(ofSize: 13)
            text.lineBreakMode = .byTruncatingTail
            for view in [image, text] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 22), image.heightAnchor.constraint(equalToConstant: 22),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.imageView = image
            cell.textField = text
            return cell
        }()
        cell.textField?.stringValue = app.name
        cell.imageView?.image = icon(app.path)
        return cell
    }

    private func icon(_ path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    // MARK: Apps

    /// The usual app folders, one level deep (Utilities included).
    static func installedApps() -> [Launcher.App] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            home + "/Applications", home + "/Applications/Chrome Apps.localized",
        ]
        // Apps that live elsewhere but users expect to find.
        let extras = ["/System/Library/CoreServices/Finder.app"]
        var seen: Set<String> = []
        var apps: [Launcher.App] = []
        for folder in folders {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where entry.hasSuffix(".app") {
                let path = (folder as NSString).appendingPathComponent(entry)
                guard seen.insert(path).inserted else { continue }
                var name = FileManager.default.displayName(atPath: path)
                if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
                apps.append(Launcher.App(name: name, path: path))
            }
        }
        for path in extras where FileManager.default.fileExists(atPath: path) && seen.insert(path).inserted {
            apps.append(Launcher.App(name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""), path: path))
        }
        return apps
    }
}

/// A borderless panel may only take the keyboard if it says so.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
