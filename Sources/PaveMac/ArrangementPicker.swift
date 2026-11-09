import AppKit
import PaveCore

/// The arrangement picker (⌃⇧A): the saved arrangements, numbered. 1…9 or
/// Return restores, S saves the current windows. Keys come from the tap: the
/// panel never takes focus nor the mouse.
@MainActor
public final class ArrangementPicker {
    public struct Row {
        public var name: String
        /// "6 windows · 3 apps".
        public var detail: String
        public init(name: String, detail: String) {
            self.name = name
            self.detail = detail
        }
    }

    private let panel: NSPanel
    private let view = ListView()
    private var session: Int?
    private var rows: [Row] = []
    public var onRestore: (String) -> Void = { _ in }
    public var onSave: () -> Void = {}
    public var onClose: (Int) -> Void = { _ in }

    public var isOpen: Bool { session != nil }

    public init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        background.addSubview(view)
        panel.contentView = background
    }

    /// `area`: the usable area of the screen to center on (AX).
    public func open(id: Int, area: Rect, rows: [Row]) {
        session = id
        self.rows = rows
        view.rows = rows
        view.selected = 0
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(
            Screens.appKit(Rect(
                x: (area.x + (area.width - size.width) / 2).rounded(), y: (area.y + (area.height - size.height) / 2).rounded(),
                width: size.width, height: size.height)),
            display: true)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    public func handle(_ key: HotkeyService.PickerKey) {
        guard session != nil else { return }
        switch key {
        case .open: return
        case .next, .down, .right: move(1)
        case .previous, .up, .left: move(-1)
        case .digit(let n): close { if n <= self.rows.count { self.onRestore(self.rows[n - 1].name) } }
        case .commit: close { if !self.rows.isEmpty { self.onRestore(self.rows[self.view.selected].name) } }
        case .letter("s"): close { self.onSave() }
        case .letter, .cancel: close {}
        }
    }

    private func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        view.selected = ((view.selected + step) % rows.count + rows.count) % rows.count
        view.needsDisplay = true
    }

    private func close(then action: @escaping () -> Void) {
        guard let id = session else { return }
        session = nil
        panel.orderOut(nil)
        onClose(id)
        action()
    }
}

private final class ListView: NSView {
    var rows: [ArrangementPicker.Row] = []
    var selected = 0

    static let width: Double = 380
    static let rowHeight: Double = 40
    static let padding: Double = 18
    static let titleHeight: Double = 32
    static let footerHeight: Double = 28

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let count = max(rows.count, 1)
        return NSSize(width: Self.width, height: Self.padding * 2 + Self.titleHeight + Double(count) * Self.rowHeight + Self.footerHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor]
        NSAttributedString(string: String(localized: "Window arrangements"), attributes: title).draw(at: NSPoint(x: Self.padding, y: Self.padding))
        var y = Self.padding + Self.titleHeight
        if rows.isEmpty {
            let empty: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            NSAttributedString(string: String(localized: "None yet: S saves the windows as they are now."), attributes: empty)
                .draw(at: NSPoint(x: Self.padding, y: y + 11))
        }
        for (i, row) in rows.enumerated() {
            let rect = NSRect(x: Self.padding - 6, y: y, width: Self.width - 2 * Self.padding + 12, height: Self.rowHeight - 4)
            if i == selected {
                NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            }
            let number: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ]
            if i < 9 { NSAttributedString(string: "\(i + 1)", attributes: number).draw(at: NSPoint(x: Self.padding, y: y + 10)) }
            let name: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: i == selected ? .semibold : .regular), .foregroundColor: NSColor.labelColor]
            NSAttributedString(string: row.name, attributes: name).draw(at: NSPoint(x: Self.padding + 22, y: y + 9))
            let detail: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            let text = NSAttributedString(string: row.detail, attributes: detail)
            text.draw(at: NSPoint(x: Self.width - Self.padding - text.size().width, y: y + 11))
            y += Self.rowHeight
        }
        let hint: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]
        NSAttributedString(string: String(localized: "1–9 restore · ↩ restore · S save current · esc cancel"), attributes: hint)
            .draw(at: NSPoint(x: Self.padding, y: bounds.height - Self.padding - 16))
    }
}
