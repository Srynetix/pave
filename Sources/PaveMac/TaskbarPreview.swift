// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// Window previews above a taskbar entry.
///
/// One card per window of the entry (a row for a group): title, preview from
/// the ThumbnailService cache, app icon when there is none (minimized, no
/// Screen Recording permission). Click a card: that window comes to the front;
/// × closes it. Never takes the focus. Images stay in memory, never logged.
@MainActor
final class TaskbarPreview {
    static let cardSize = NSSize(width: 220, height: 150)
    static let titleHeight: CGFloat = 22
    static let padding: CGFloat = 8

    let panel: NSPanel
    private let background = NSVisualEffectView()
    private var cards: [PreviewCard] = []
    private var tracker: HoverView!
    private(set) var windowIDs: [WindowID] = []
    var onPick: (WindowID) -> Void = { _ in }
    var onClose: (WindowID) -> Void = { _ in }
    /// The cursor entered / left the preview (to keep it open while it is used).
    var onHover: (Bool) -> Void = { _ in }

    init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        tracker = HoverView { [weak self] inside in self?.onHover(inside) }
        background.addSubview(tracker)
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    /// First display is slow (panel, material, cards: up to ~145 ms
    /// measured): do it once, invisibly, as the switcher does.
    func prewarm(cards count: Int = 4) {
        while cards.count < count {
            let card = PreviewCard()
            cards.append(card)
            background.addSubview(card)
        }
        panel.alphaValue = 0
        panel.setFrame(NSRect(x: -10_000, y: -10_000, width: 300, height: 170), display: true)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// Shows the cards of `windows` above `anchor` (an entry of the bar).
    func show(_ windows: [WindowSnapshot], images: (WindowID) -> CGImage?, icon: NSImage, above anchor: NSView) {
        windowIDs = windows.map(\.id)
        while cards.count < windows.count {
            let card = PreviewCard()
            cards.append(card)
            background.addSubview(card)
        }
        let size = Self.cardSize
        for (index, card) in cards.enumerated() {
            guard index < windows.count else {
                card.isHidden = true
                continue
            }
            let window = windows[index]
            card.isHidden = false
            card.frame = NSRect(
                x: Self.padding + CGFloat(index) * (size.width + Self.padding), y: Self.padding,
                width: size.width, height: size.height)
            card.configure(window, image: images(window.id), icon: icon)
            card.onPick = { [weak self] in self?.onPick(window.id) }
            card.onClose = { [weak self] in self?.onClose(window.id) }
        }
        // Above the entry, centered on it, kept inside its screen.
        guard let anchorWindow = anchor.window, let screen = anchorWindow.screen else { return }
        let width = Self.padding + CGFloat(windows.count) * (size.width + Self.padding)
        let height = size.height + 2 * Self.padding
        let entry = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var x = entry.midX - width / 2
        x = min(max(x, screen.frame.minX + 6), screen.frame.maxX - width - 6)
        panel.setFrame(NSRect(x: x, y: anchorWindow.frame.maxY + 6, width: width, height: height), display: true)
        tracker.frame = background.bounds
        panel.orderFrontRegardless()
    }

    func update(_ id: WindowID, _ image: CGImage) {
        guard let index = windowIDs.firstIndex(of: id), index < cards.count else { return }
        cards[index].setImage(image)
    }

    func hide() {
        windowIDs = []
        panel.orderOut(nil)
    }
}

/// Reports the cursor entering / leaving its bounds (panel never key).
@MainActor
final class HoverView: NSView {
    private let handler: (Bool) -> Void
    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { handler(true) }
    override func mouseExited(with event: NSEvent) { handler(false) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks go to the cards
}

@MainActor
final class PreviewCard: NSView {
    private let title = NSTextField(labelWithString: "")
    private let appIcon = NSImageView()
    private let preview = CALayer()
    private let placeholder = NSImageView()
    private let close = NSButton(title: "✕", target: nil, action: nil)
    private var hovered = false
    var onPick: () -> Void = {}
    var onClose: () -> Void = {}

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        title.font = .systemFont(ofSize: 11)
        title.lineBreakMode = .byTruncatingTail
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        placeholder.imageScaling = .scaleProportionallyUpOrDown
        preview.contentsGravity = .resizeAspect
        preview.cornerRadius = 4
        preview.masksToBounds = true
        close.isBordered = false
        close.font = .systemFont(ofSize: 11, weight: .semibold)
        close.target = self
        close.action = #selector(closeTapped)
        close.isHidden = true
        for view in [title, appIcon, placeholder, close] { addSubview(view) }
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let h = TaskbarPreview.titleHeight
        appIcon.frame = NSRect(x: 6, y: bounds.height - h + 3, width: 16, height: 16)
        title.frame = NSRect(x: 26, y: bounds.height - h + 3, width: bounds.width - 52, height: 16)
        close.frame = NSRect(x: bounds.width - 24, y: bounds.height - h + 1, width: 20, height: 20)
        let area = NSRect(x: 6, y: 6, width: bounds.width - 12, height: bounds.height - h - 8)
        preview.frame = area
        placeholder.frame = area.insetBy(dx: area.width / 2 - 24, dy: area.height / 2 - 24)
    }

    func configure(_ window: WindowSnapshot, image: CGImage?, icon: NSImage) {
        title.stringValue = window.title.isEmpty ? window.appName : window.title
        appIcon.image = icon
        placeholder.image = icon
        setImage(image)
        alphaValue = window.state == .normal || window.state == .fullscreen ? 1 : 0.75
        needsLayout = true
    }

    func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.contents = image
        CATransaction.commit()
        placeholder.isHidden = image != nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        close.isHidden = false
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        close.isHidden = true
        layer?.backgroundColor = nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick() }
    }

    @objc private func closeTapped() { onClose() }
}
