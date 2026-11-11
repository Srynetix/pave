// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// The zone layout editor (Z4): full screen on the screen it edits, the zones
/// at their real size. Click a zone to select it, ⇧-click a neighbour to
/// merge with it, drag the lines between zones (5 % steps, ⇧: 1 %).
/// It takes the keyboard while open (it is a real window), and gives the
/// focus back to the app that had it when it closes.
@MainActor
public final class ZoneEditor {
    public struct Request {
        /// The screen edited (AX coordinates).
        public var screen: Screen
        public var screenName: String
        /// Where the editing starts.
        public var layout: ZoneLayout
        /// Proposed name: the user's layout being edited, else empty.
        public var name: String
        public var gaps: Int
        public init(screen: Screen, screenName: String, layout: ZoneLayout, name: String, gaps: Int) {
            self.screen = screen
            self.screenName = screenName
            self.layout = layout
            self.name = name
            self.gaps = gaps
        }
    }

    /// Saved: the layout (named) and the gaps. Returns nil if written, else
    /// why not (shown in the editor, which stays open).
    public var onSave: (ZoneLayout, Int) -> String? = { _, _ in nil }

    private var window: EditorWindow?
    private var previousApp: NSRunningApplication?

    public init() {}

    public var isOpen: Bool { window != nil }

    public func open(_ request: Request) {
        close(restoreFocus: false)
        previousApp = NSWorkspace.shared.frontmostApplication
        let window = EditorWindow(request: request)
        window.editor.onCancel = { [weak self] in
            Log.info("zones: editor cancelled")
            self?.close(restoreFocus: true)
        }
        window.editor.onSave = { [weak self] layout, gaps in
            guard let self else { return nil }
            if let problem = self.onSave(layout, gaps) { return problem }
            self.close(restoreFocus: true)
            return nil
        }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.editor)
        Log.info(
            "zones: editor opened on \(request.screenName), from \(request.layout.name) (\(request.layout.zones.count) zones)"
        )
    }

    private func close(restoreFocus: Bool) {
        guard let window else { return }
        self.window = nil
        window.orderOut(nil)
        if restoreFocus, let app = previousApp, app != NSRunningApplication.current { app.activate() }
        previousApp = nil
    }
}

private final class EditorWindow: NSWindow {
    let editor: EditorView

    init(request: ZoneEditor.Request) {
        editor = EditorView(request: request)
        super.init(
            contentRect: Screens.appKit(request.screen.frame), styleMask: [.borderless], backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)  // over the taskbar and menu bar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = editor
        setFrame(Screens.appKit(request.screen.frame), display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { editor.onCancel() }
}

private final class EditorView: NSView, NSTextFieldDelegate {
    var onCancel: () -> Void = {}
    var onSave: (ZoneLayout, Int) -> String? = { _, _ in nil }

    private let request: ZoneEditor.Request
    private var draft: ZoneDraft
    private var gaps: Int
    private var selected: Int? = 0
    /// ⇧-clicked neighbour, merged with the selection by Merge.
    private var secondary: Int?
    private var dragging: ZoneDraft.Separator?
    private var hovered: ZoneDraft.Separator?
    private var message: String?

    private let toolbar = NSVisualEffectView()
    private let nameField = NSTextField()
    private let gapsLabel = NSTextField(labelWithString: "")
    private let gapsStepper = NSStepper()
    private let hint = NSTextField(labelWithString: "")
    private var buttons: [String: NSButton] = [:]

    /// The usable area, in this view's (flipped) coordinates.
    private var area: Rect {
        let f = request.screen.frame
        let v = request.screen.visibleFrame
        return Rect(x: v.x - f.x, y: v.y - f.y, width: v.width, height: v.height)
    }

    init(request: ZoneEditor.Request) {
        self.request = request
        draft = ZoneDraft(request.layout)
        gaps = request.gaps
        super.init(
            frame: NSRect(
                origin: .zero, size: NSSize(width: request.screen.frame.width, height: request.screen.frame.height)))
        buildToolbar()
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Toolbar

    private func buildToolbar() {
        toolbar.material = .hudWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 12

        let templates = NSPopUpButton(frame: .zero, pullsDown: true)
        templates.addItem(withTitle: String(localized: "Start from…"))
        for layout in ZoneLayout.builtIn { templates.addItem(withTitle: layout.name) }
        templates.target = self
        templates.action = #selector(startFrom(_:))

        func button(_ key: String, _ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            buttons[key] = b
            return b
        }
        gapsStepper.minValue = 0
        gapsStepper.maxValue = 64
        gapsStepper.increment = 2
        gapsStepper.integerValue = gaps
        gapsStepper.target = self
        gapsStepper.action = #selector(gapsChanged)

        nameField.placeholderString = String(localized: "Layout name")
        nameField.stringValue = request.name
        nameField.delegate = self
        nameField.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let save = button("save", String(localized: "Save"), #selector(save))
        save.keyEquivalent = "\r"
        let row = NSStackView(views: [
            templates,
            separatorView(),
            button("columns", String(localized: "Split into columns"), #selector(splitColumns)),
            button("rows", String(localized: "Split into rows"), #selector(splitRows)),
            button("merge", String(localized: "Merge"), #selector(merge)),
            button("delete", String(localized: "Delete"), #selector(deleteZone)),
            button("undo", String(localized: "Undo"), #selector(undo)),
            separatorView(),
            gapsLabel, gapsStepper,
            separatorView(),
            nameField,
            button("cancel", String(localized: "Cancel"), #selector(cancel)),
            save,
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            row.topAnchor.constraint(equalTo: toolbar.topAnchor),
            row.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])
        addSubview(toolbar)
        let size = row.fittingSize
        toolbar.frame = NSRect(
            x: (area.x + (area.width - size.width) / 2).rounded(), y: area.y + 16, width: size.width,
            height: size.height)

        hint.textColor = .white.withAlphaComponent(0.75)
        hint.font = .systemFont(ofSize: 12)
        addSubview(hint)
    }

    private func separatorView() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func updateControls() {
        let one = selected != nil
        buttons["columns"]?.isEnabled = one
        buttons["rows"]?.isEnabled = one
        buttons["delete"]?.isEnabled = one && draft.zones.count > 1
        buttons["merge"]?.isEnabled = selected != nil && secondary != nil
        buttons["undo"]?.isEnabled = draft.canUndo
        buttons["save"]?.isEnabled = ZoneLayout.isValidName(nameField.stringValue.trimmedForName)
        gapsLabel.stringValue = String(localized: "Gaps \(gaps)")
        hint.stringValue =
            message
            ?? String(
                localized:
                    "Click a zone · ⇧-click a neighbour, then Merge · drag the lines (⇧: 1 %) · V / H split · ⌫ delete · ⌘Z undo · esc cancel"
            )
        hint.textColor = message == nil ? .white.withAlphaComponent(0.75) : .systemOrange
        hint.sizeToFit()
        hint.frame.origin = NSPoint(
            x: (area.x + (area.width - hint.frame.width) / 2).rounded(), y: toolbar.frame.maxY + 8)
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        message = nil
        updateControls()
    }

    // MARK: Actions

    @objc private func startFrom(_ sender: NSPopUpButton) {
        guard let layout = ZoneLayout.builtIn.first(where: { $0.name == sender.titleOfSelectedItem }) else { return }
        draft.replace(with: layout)
        select(0)
    }

    @objc private func splitColumns() { split(columns: true) }
    @objc private func splitRows() { split(columns: false) }

    private func split(columns: Bool) {
        guard let i = selected else { return }
        if let first = draft.split(i, columns: columns) {
            select(first)
        } else {
            flash(
                draft.zones.count >= ZoneLayout.maxZones
                    ? String(localized: "At most \(ZoneLayout.maxZones) zones")
                    : String(localized: "This zone is too small to split"))
        }
    }

    @objc private func merge() {
        guard let i = selected, let j = secondary else { return }
        if let merged = draft.merge(i, j) {
            select(merged)
        } else {
            flash(String(localized: "Only two zones that make a rectangle together can merge"))
        }
    }

    @objc private func deleteZone() {
        guard let i = selected, draft.remove(i) else { return }
        select(nil)
    }

    @objc private func undo() {
        draft.undo()
        select(selected.flatMap { draft.zones.indices.contains($0) ? $0 : nil })
    }

    @objc private func gapsChanged() {
        gaps = gapsStepper.integerValue
        updateControls()
    }

    @objc private func cancel() { onCancel() }

    @objc private func save() {
        let name = nameField.stringValue.trimmedForName
        guard ZoneLayout.isValidName(name) else {
            return flash(String(localized: "A name of letters, digits, spaces, - or _"))
        }
        guard !ZoneLayout.builtIn.contains(where: { $0.name == name }) else {
            return flash(String(localized: "\(name) is a built-in layout: choose another name"))
        }
        do {
            let layout = try draft.layout(named: name)
            if let problem = onSave(layout, gaps) { flash(problem) }
        } catch {
            flash(error.message)
        }
    }

    private func select(_ i: Int?) {
        selected = i
        secondary = nil
        message = nil
        updateControls()
    }

    private func flash(_ text: String) {
        message = text
        updateControls()
        NSSound.beep()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, key) {
        case (53, _): onCancel()  // escape
        case (51, _), (117, _): deleteZone()  // delete, forward delete
        case (48, _):  // tab: next zone
            let count = draft.zones.count
            select(((selected ?? -1) + (event.modifierFlags.contains(.shift) ? count - 1 : 1)) % count)
        case (_, "z") where !mods.isEmpty: undo()
        case (_, "v") where mods.isEmpty: splitColumns()
        case (_, "h") where mods.isEmpty: splitRows()
        case (_, "m") where mods.isEmpty: merge()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    private func percent(_ p: NSPoint) -> (x: Double, y: Double) {
        ((p.x - area.x) / area.width * 100, (p.y - area.y) / area.height * 100)
    }

    /// The line under the point, within 6 pt.
    private func separator(at p: NSPoint) -> ZoneDraft.Separator? {
        let a = area
        return draft.separators.first { s in
            let start = (s.vertical ? a.y + a.height * Double(s.start) / 100 : a.x + a.width * Double(s.start) / 100)
            let end = (s.vertical ? a.y + a.height * Double(s.end) / 100 : a.x + a.width * Double(s.end) / 100)
            let line = s.vertical ? a.x + a.width * Double(s.position) / 100 : a.y + a.height * Double(s.position) / 100
            let (along, across) = s.vertical ? (p.y, p.x) : (p.x, p.y)
            return abs(across - line) <= 6 && along >= start && along <= end
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let line = separator(at: convert(event.locationInWindow, from: nil))
        if line != hovered {
            hovered = line
            needsDisplay = true
        }
        (line.map { $0.vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown } ?? NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let line = separator(at: p) {
            draft.beginMove()
            dragging = line
            return
        }
        let (x, y) = percent(p)
        guard let hit = draft.zone(atX: x, y: y) else { return select(nil) }
        if event.modifierFlags.contains(.shift), let current = selected, current != hit {
            secondary = hit
            message = nil
            updateControls()
        } else {
            select(hit)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let line = dragging else { return }
        let (x, y) = percent(convert(event.locationInWindow, from: nil))
        let target = Int((line.vertical ? x : y).rounded())
        dragging = draft.move(line, to: target, step: event.modifierFlags.contains(.shift) ? 1 : ZoneDraft.step)
        hovered = dragging
        updateControls()
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        updateControls()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.6).setFill()
        bounds.fill()
        let accent = NSColor.controlAccentColor
        guard let layout = try? draft.layout(named: "draft") else { return }
        let frames = layout.frames(in: area, gaps: Double(gaps))
        let big = NSFont.systemFont(ofSize: 64, weight: .semibold)
        let small = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        for (i, f) in frames.enumerated() {
            let rect = NSRect(x: f.x, y: f.y, width: f.width, height: f.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            let isSelected = i == selected
            let isSecondary = i == secondary
            (isSelected
                ? accent.withAlphaComponent(0.45)
                : isSecondary ? accent.withAlphaComponent(0.25) : NSColor.white.withAlphaComponent(0.12)).setFill()
            path.fill()
            (isSelected || isSecondary ? accent : NSColor.white.withAlphaComponent(0.5)).setStroke()
            path.lineWidth = isSelected ? 3 : 1.5
            if isSecondary { path.setLineDash([8, 5], count: 2, phase: 0) }
            path.stroke()
            let number = NSAttributedString(
                string: "\(i + 1)", attributes: [.font: big, .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
            let size = number.size()
            if rect.width > size.width + 8, rect.height > size.height + 40 {
                number.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - 10))
            }
            // Size in percent and points, under the number.
            let z = draft.zones[i]
            let label = NSAttributedString(
                string: "\(z.width) × \(z.height) %  ·  \(Int(f.width)) × \(Int(f.height))",
                attributes: [.font: small, .foregroundColor: NSColor.white.withAlphaComponent(0.7)])
            let ls = label.size()
            if rect.width > ls.width + 8, rect.height > size.height + ls.height + 40 {
                label.draw(at: NSPoint(x: rect.midX - ls.width / 2, y: rect.midY + size.height / 2 - 4))
            }
        }
        // The line under the pointer (or dragged): a handle along it.
        if let line = dragging ?? hovered {
            let a = area
            let pos =
                line.vertical
                ? a.x + a.width * Double(line.position) / 100 : a.y + a.height * Double(line.position) / 100
            let s = line.vertical ? a.y + a.height * Double(line.start) / 100 : a.x + a.width * Double(line.start) / 100
            let e = line.vertical ? a.y + a.height * Double(line.end) / 100 : a.x + a.width * Double(line.end) / 100
            let bar =
                line.vertical
                ? NSRect(x: pos - 2, y: s, width: 4, height: e - s) : NSRect(x: s, y: pos - 2, width: e - s, height: 4)
            accent.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            let tag = NSAttributedString(
                string: " \(line.position) % ",
                attributes: [.font: small, .foregroundColor: NSColor.white, .backgroundColor: accent])
            let mid = (s + e) / 2
            tag.draw(at: line.vertical ? NSPoint(x: pos + 8, y: mid) : NSPoint(x: mid, y: pos + 8))
        }
    }
}

extension String {
    fileprivate var trimmedForName: String { trimmingCharacters(in: .whitespaces) }
}
