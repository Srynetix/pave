// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// The switcher's on-screen panel.
///
/// - Never becomes key or main: the window the user was in stays the active
///   one, so "previous window" keeps its meaning; the keyboard goes through
///   the event tap, not through this panel.
/// - Built once and reused: opening only updates the cards (< 50 ms).
/// - Light / dark follow the system through the HUD material and semantic colors.
/// - Without a cached preview, the preview area shows the app icon.
@MainActor
public final class SwitcherPanel {
    /// Click on a card.
    public var onPick: ((WindowID) -> Void)?
    /// Preview of a window, if one is cached.
    public var previewFor: ((WindowID) -> CGImage?)?
    /// Cards per row of the last layout (for ↑ / ↓).
    public private(set) var columns = 1

    private let panel: NonActivatingPanel
    private let background = NSVisualEffectView()
    private let searchLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: String(localized: "No windows"))
    private var cards: [CardView] = []
    private var icons: [PID: NSImage] = [:]

    enum Metrics {
        static let card = NSSize(width: 196, height: 164)
        static let preview = NSSize(width: 176, height: 108)
        static let spacing: CGFloat = 10
        static let padding: CGFloat = 18
        static let searchHeight: CGFloat = 30
        /// Share of the screen the panel may use.
        static let maxScreenShare: CGFloat = 0.85
    }

    public init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        panel.contentView = background

        searchLabel.font = .systemFont(ofSize: 15, weight: .medium)
        searchLabel.textColor = .labelColor
        searchLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        background.addSubview(searchLabel)
        background.addSubview(emptyLabel)
    }

    public var isVisible: Bool { panel.isVisible }

    /// `point` in screen coordinates (`NSEvent.mouseLocation`).
    public func contains(_ point: NSPoint) -> Bool { panel.isVisible && panel.frame.contains(point) }

    /// Shows or updates the panel for `session`; nil hides it.
    public func show(_ session: SwitcherSession?) {
        guard let session else {
            panel.orderOut(nil)
            return
        }
        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        layout(session, on: screen.visibleFrame)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Lays out and renders the panel fully transparent, then hides it, so the
    /// first real opening finds everything built and cached.
    public func prewarm(_ session: SwitcherSession) {
        panel.alphaValue = 0
        show(session)
        panel.displayIfNeeded()
        CATransaction.flush()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    // MARK: - Layout

    private func layout(_ session: SwitcherSession, on area: NSRect) {
        let entries = session.entries
        let searching = session.mode == .search
        let maxWidth = area.width * Metrics.maxScreenShare
        let maxHeight = area.height * Metrics.maxScreenShare
        let step = Metrics.card.width + Metrics.spacing
        let fit = max(1, Int((maxWidth - 2 * Metrics.padding + Metrics.spacing) / step))
        columns = max(1, min(fit, max(entries.count, 1)))
        let rows = max(1, Int((Double(entries.count) / Double(columns)).rounded(.up)))

        // Too many rows for the screen: scale the cards down rather than scroll.
        let header = searching ? Metrics.searchHeight : 0
        let naturalHeight = CGFloat(rows) * (Metrics.card.height + Metrics.spacing) - Metrics.spacing
        let scale = min(1, (maxHeight - 2 * Metrics.padding - header) / naturalHeight)
        let card = NSSize(width: Metrics.card.width * scale, height: Metrics.card.height * scale)
        let spacing = Metrics.spacing * scale

        let gridWidth = CGFloat(columns) * (card.width + spacing) - spacing
        let gridHeight = CGFloat(rows) * (card.height + spacing) - spacing
        let width = max(gridWidth, searching ? 360 : 0) + 2 * Metrics.padding
        let height = (entries.isEmpty ? 60 : gridHeight) + header + 2 * Metrics.padding
        let frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height).integral
        if panel.frame != frame { panel.setFrame(frame, display: false) }

        searchLabel.isHidden = !searching
        searchLabel.stringValue = "🔍 " + (session.query.isEmpty ? String(localized: "Type to search…") : session.query)
        searchLabel.textColor = session.query.isEmpty ? .secondaryLabelColor : .labelColor
        searchLabel.frame = NSRect(
            x: Metrics.padding, y: height - Metrics.padding - header + 4, width: width - 2 * Metrics.padding, height: 22
        )
        emptyLabel.isHidden = !entries.isEmpty
        emptyLabel.frame = NSRect(x: 0, y: Metrics.padding + 18, width: width, height: 24)

        while cards.count < entries.count {
            let view = CardView()
            view.onClick = { [weak self] id in self?.onPick?(id) }
            background.addSubview(view)
            cards.append(view)
        }
        let top = height - Metrics.padding - header
        for (index, view) in cards.enumerated() {
            guard index < entries.count else {
                view.isHidden = true
                continue
            }
            let entry = entries[index]
            let column = index % columns
            let row = index / columns
            view.frame = NSRect(
                x: Metrics.padding + CGFloat(column) * (card.width + spacing),
                y: top - CGFloat(row + 1) * card.height - CGFloat(row) * spacing,
                width: card.width, height: card.height)
            view.isHidden = false
            view.configure(
                entry, icon: icon(for: entry.pid), preview: previewFor?(entry.id),
                selected: index == session.selection, scale: scale)
        }
    }

    /// A capture arrived: update that card only.
    public func updatePreview(_ id: WindowID, _ image: CGImage) {
        guard panel.isVisible else { return }
        cards.first { !$0.isHidden && $0.windowID == id }?.setPreview(image)
    }

    private func icon(for pid: PID) -> NSImage {
        if let cached = icons[pid] { return cached }
        let image = NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(named: NSImage.applicationIconName)!
        icons[pid] = image
        return image
    }

    /// Apps quit: drop their icons.
    public func forgetIcons(except alive: Set<PID>) {
        icons = icons.filter { alive.contains($0.key) }
    }
}

/// Never key, never main: the switcher must not take the focus.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One window in the grid: preview area (or the app icon), title, app, state badge.
@MainActor
final class CardView: NSView {
    var onClick: ((WindowID) -> Void)?
    private var id: WindowID?
    var windowID: WindowID? { id }
    private let selection = NSView()
    private let preview = NSView()
    /// The window capture, aspect-fit in the preview area.
    private let shot = CALayer()
    private let bigIcon = NSImageView()
    private let smallIcon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let app = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        selection.wantsLayer = true
        selection.layer?.cornerRadius = 12
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        bigIcon.imageScaling = .scaleProportionallyUpOrDown
        smallIcon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = .labelColor
        app.font = .systemFont(ofSize: 11)
        app.textColor = .secondaryLabelColor
        app.lineBreakMode = .byTruncatingTail
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.85).cgColor
        for view in [selection, preview, smallIcon, title, app] { addSubview(view) }
        shot.contentsGravity = .resizeAspect
        shot.minificationFilter = .trilinear
        preview.layer?.addSublayer(shot)
        preview.addSubview(bigIcon)
        preview.addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(
        _ entry: SwitcherSession.Entry, icon: NSImage, preview image: CGImage?, selected: Bool, scale: CGFloat
    ) {
        id = entry.id
        let w = bounds.width
        let h = bounds.height
        let inset = 10 * scale
        selection.frame = bounds
        selection.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor : nil

        let previewHeight = h - 46 * scale - inset
        preview.frame = NSRect(x: inset, y: h - inset - previewHeight, width: w - 2 * inset, height: previewHeight)
        preview.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        let side = min(preview.bounds.height * 0.6, 72 * scale)
        bigIcon.frame = NSRect(
            x: (preview.bounds.width - side) / 2, y: (preview.bounds.height - side) / 2, width: side, height: side)
        bigIcon.image = icon
        bigIcon.alphaValue = entry.state == .normal ? 1 : 0.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shot.frame = preview.bounds.insetBy(dx: 4, dy: 4)
        shot.opacity = entry.state == .normal || entry.state == .fullscreen ? 1 : 0.55
        CATransaction.commit()
        setPreview(image)

        let badgeText: String? =
            switch entry.state {
            case .normal: nil
            case .minimized: String(localized: "minimized")
            case .hidden: String(localized: "hidden")
            case .fullscreen: String(localized: "full screen")
            }
        badge.isHidden = badgeText == nil
        badge.stringValue = badgeText ?? ""
        badge.sizeToFit()
        badge.frame = NSRect(x: 6, y: 6, width: badge.frame.width + 10, height: 16)

        let iconSide = 16 * scale
        smallIcon.frame = NSRect(x: inset, y: inset + 16 * scale, width: iconSide, height: iconSide)
        smallIcon.image = icon
        title.font = .systemFont(ofSize: 12 * scale, weight: .medium)
        title.stringValue = entry.title.isEmpty ? entry.appName : entry.title
        title.frame = NSRect(
            x: inset + iconSide + 5, y: inset + 14 * scale, width: w - 2 * inset - iconSide - 5, height: 18 * scale)
        app.font = .systemFont(ofSize: 11 * scale)
        app.stringValue = entry.appName
        app.frame = NSRect(x: inset, y: inset - 3 * scale, width: w - 2 * inset, height: 15 * scale)
    }

    /// nil: no capture (yet): the big app icon stands in.
    func setPreview(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shot.contents = image
        CATransaction.commit()
        bigIcon.isHidden = image != nil
    }

    override func mouseUp(with event: NSEvent) {
        if let id, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(id) }
    }

    /// The panel never becomes key: accept the click anyway.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
