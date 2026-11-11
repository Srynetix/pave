import AppKit
import PaveCore

/// The zone layout picker (⌃⇧Z): the layouts a screen can use, as
/// miniatures, numbered. Keys come from the tap (`HotkeyService.PickerKey`):
/// the panel never takes focus nor the mouse.
///
/// Two digits in a row place the focused window: the first picks a layout,
/// the second one of its zones (2 then 4: zone 4 of the second layout).
/// After the first, ↩ applies the layout alone, an arrow goes back to the layouts.
@MainActor
public final class ZonePicker {
    public struct Choice {
        /// Config name; `ZoneSettings.none` for halves and quarters.
        public var name: String
        /// Nil for "none".
        public var layout: ZoneLayout?
        public init(name: String, layout: ZoneLayout?) {
            self.name = name
            self.layout = layout
        }
    }

    private let panel: NSPanel
    private let view = PickerView()
    private var session: Int?
    private var choices: [Choice] = []
    /// Called with the chosen name when a choice is made (not on cancel),
    /// and the zone (from 1) to put the window in, if one was typed.
    public var onChoose: (String, Int?) -> Void = { _, _ in }
    /// A window can be placed: digits go on to a zone.
    private var canPlace = false
    /// The layout picked by a first digit, waiting for its zone's.
    private var picked: Int?
    /// Called with the selected name when E asks to edit it.
    public var onEdit: (String) -> Void = { _ in }
    /// Called when the picker closes by itself, to end the tap session.
    public var onClose: (Int) -> Void = { _ in }

    public var isOpen: Bool { session != nil }

    public init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
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

    /// `area`: the screen's usable area (AX); `current`: the layout it uses now.
    /// `canPlace`: the focused window may go into a zone (second digit).
    public func open(id: Int, area: Rect, screenName: String, choices: [Choice], current: String, canPlace: Bool) {
        session = id
        self.choices = choices
        self.canPlace = canPlace
        picked = nil
        view.picking = nil
        view.canPlace = canPlace
        view.title = screenName
        view.aspect = area.height / max(area.width, 1)
        view.choices = choices
        view.current = choices.firstIndex { $0.name == current }
        view.selected = view.current ?? 0
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let frame = Rect(
            x: (area.x + (area.width - size.width) / 2).rounded(),
            y: (area.y + (area.height - size.height) / 2).rounded(),
            width: size.width, height: size.height)
        panel.setFrame(Screens.appKit(frame), display: true)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    public func handle(_ key: HotkeyService.PickerKey) {
        guard session != nil, !choices.isEmpty else { return }
        let columns = view.columns
        switch key {
        case .open: return
        case .next, .right: move(by: 1)
        case .previous, .left: move(by: -1)
        case .down: move(by: columns)
        case .up: move(by: -columns)
        case .digit(let n):
            if let picked {
                // Its zone: a number the layout does not have is ignored.
                guard let layout = choices[picked].layout, n <= layout.zones.count else { return }
                return close(chosen: choices[picked].name, zone: n)
            }
            guard n <= choices.count else { return close(chosen: nil) }
            guard canPlace, choices[n - 1].layout?.zones.isEmpty == false else {
                return close(chosen: choices[n - 1].name)
            }
            picked = n - 1
            view.selected = n - 1
            view.picking = n - 1
            view.needsDisplay = true
        case .commit: close(chosen: choices[view.selected].name)
        case .letter("e"):
            let name = choices[view.selected].name
            close(chosen: nil)
            onEdit(name)
        case .letter: close(chosen: nil)
        case .cancel: close(chosen: nil)
        }
    }

    /// Closes without a choice (the screen went away, a drag started…).
    public func cancel() { close(chosen: nil) }

    private func move(by step: Int) {
        // Back to choosing a layout.
        picked = nil
        view.picking = nil
        let count = choices.count
        view.selected = ((view.selected + step) % count + count) % count
        view.needsDisplay = true
    }

    private func close(chosen: String?, zone: Int? = nil) {
        guard let id = session else { return }
        session = nil
        picked = nil
        panel.orderOut(nil)
        onClose(id)
        if let chosen { onChoose(chosen, zone) }
    }
}

/// Cards of miniatures, `columns` per row, drawn in one view.
private final class PickerView: NSView {
    var title = ""
    var aspect: Double = 9.0 / 16
    var choices: [ZonePicker.Choice] = []
    var current: Int?
    var selected = 0
    /// The layout whose zone is being typed (second digit).
    var picking: Int?
    var canPlace = false

    static let cardWidth: Double = 168
    static let gap: Double = 14
    static let padding: Double = 22
    static let titleHeight: Double = 34
    static let footerHeight: Double = 30
    static let labelHeight: Double = 24

    override var isFlipped: Bool { true }

    var columns: Int { min(max(choices.count, 1), 5) }
    private var rows: Int { (choices.count + columns - 1) / columns }
    private var miniatureHeight: Double { (Self.cardWidth * aspect).rounded() }
    private var cardHeight: Double { miniatureHeight + Self.labelHeight }

    override var fittingSize: NSSize {
        let width = Self.padding * 2 + Double(columns) * Self.cardWidth + Double(columns - 1) * Self.gap
        let height =
            Self.padding * 2 + Self.titleHeight + Double(rows) * cardHeight + Double(rows - 1) * Self.gap
            + Self.footerHeight
        return NSSize(width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]
        NSAttributedString(string: String(localized: "Zone layout · \(title)"), attributes: titleAttributes)
            .draw(at: NSPoint(x: Self.padding, y: Self.padding))

        for (i, choice) in choices.enumerated() {
            let column = i % columns
            let row = i / columns
            let x = Self.padding + Double(column) * (Self.cardWidth + Self.gap)
            let y = Self.padding + Self.titleHeight + Double(row) * (cardHeight + Self.gap)
            let miniature = NSRect(x: x, y: y, width: Self.cardWidth, height: miniatureHeight)
            // Choosing a zone: the other layouts fade.
            let faded = picking != nil && picking != i
            if faded { NSGraphicsContext.current?.cgContext.setAlpha(0.35) }
            defer { if faded { NSGraphicsContext.current?.cgContext.setAlpha(1) } }
            drawMiniature(choice.layout, in: miniature, lit: i == selected, large: picking == i)
            if i == selected {
                let ring = NSBezierPath(roundedRect: miniature.insetBy(dx: -4, dy: -4), xRadius: 10, yRadius: 10)
                ring.lineWidth = 3
                accent.setStroke()
                ring.stroke()
            }
            // "1  focus" under the miniature; "•" marks the current layout.
            let name = choice.layout == nil ? String(localized: "None (halves)") : choice.name
            let label = (i < 9 ? "\(i + 1)  " : "") + name + (i == current ? "  •" : "")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: i == selected ? .semibold : .regular),
                .foregroundColor: i == selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let text = NSAttributedString(string: label, attributes: attributes)
            text.draw(
                with: NSRect(x: x, y: y + miniatureHeight + 5, width: Self.cardWidth, height: Self.labelHeight - 5),
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }

        let hint: String =
            if let picking, let count = choices[picking].layout?.zones.count {
                String(
                    localized:
                        "1–\(min(count, 9)) put the window in that zone · ↩ apply the layout only · arrows back · esc cancel"
                )
            } else if canPlace {
                String(
                    localized:
                        "1–9 choose, then a zone's number puts the window there · arrows move · ↩ apply · E edit · esc cancel"
                )
            } else {
                String(localized: "1–9 choose · arrows move · ↩ apply · E edit · esc cancel")
            }
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        NSAttributedString(string: hint, attributes: hintAttributes)
            .draw(at: NSPoint(x: Self.padding, y: bounds.height - Self.padding - 16))
    }

    /// `large`: its zone numbers bigger, they are what is typed next.
    private func drawMiniature(_ layout: ZoneLayout?, in rect: NSRect, lit: Bool, large: Bool = false) {
        let screen = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.25).setFill()
        screen.fill()
        let area = Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        // "None": the halves, dashed, as a reminder of what applies.
        let frames: [Rect]
        if let layout {
            frames = layout.frames(in: area, gaps: 4)
        } else {
            let halves: [Rect] = [Placement.left.frame(in: area), Placement.right.frame(in: area)]
            frames = halves.map { (r: Rect) -> Rect in
                Rect(x: r.x + 4, y: r.y + 4, width: r.width - 8, height: r.height - 8)
            }
        }
        for (i, f) in frames.enumerated() {
            let zone = NSBezierPath(
                roundedRect: NSRect(x: f.x, y: f.y, width: f.width, height: f.height), xRadius: 4, yRadius: 4)
            (lit && layout != nil
                ? NSColor.controlAccentColor.withAlphaComponent(0.4) : NSColor.white.withAlphaComponent(0.12)).setFill()
            zone.fill()
            NSColor.white.withAlphaComponent(0.5).setStroke()
            zone.lineWidth = 1
            if layout == nil { zone.setLineDash([4, 3], count: 2, phase: 0) }
            zone.stroke()
            guard layout != nil else { continue }
            let number = NSAttributedString(
                string: "\(i + 1)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: large ? 17 : 11, weight: large ? .bold : .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(large ? 1 : 0.8),
                ])
            let size = number.size()
            if f.width > size.width + 4, f.height > size.height + 4 {
                number.draw(at: NSPoint(x: f.x + (f.width - size.width) / 2, y: f.y + (f.height - size.height) / 2))
            }
        }
    }
}
