import AppKit
import PaveCore

/// One taskbar, at the bottom of one screen.
///
/// A non-activating panel above normal windows: it never takes the focus,
/// never shows in ⌘Tab nor in Pavé's switcher, sits on every Space and stays
/// out of native full-screen Spaces. Entries are views reused from one update
/// to the next; only what changed is touched. Titles are drawn, never logged.
@MainActor
final class TaskbarPanel {
    static let height: CGFloat = 40

    let panel: NSPanel
    private let background = BarBackground()
    /// Right click on an empty part of the bar.
    var onRightClick: (NSEvent, NSView) -> Void {
        get { background.onRightClick }
        set { background.onRightClick = newValue }
    }
    private let entries = NSView()
    private var buttons: [TaskbarButton] = []
    private var shown: [TaskbarItem] = []
    private var overflowLabel = NSTextField(labelWithString: "")
    /// Start (launcher) on the left, Trash on the right.
    let startButton: BarIconButton = {
        let button = BarIconButton(symbol: "apple.logo", label: String(localized: "Start"))
        // The icon of macOS's own app launcher ("Apps"), else the Apple logo.
        let apps = "/System/Applications/Apps.app"
        if FileManager.default.fileExists(atPath: apps) { button.setImage(NSWorkspace.shared.icon(forFile: apps)) }
        return button
    }()
    let trashButton = BarIconButton(symbol: "trash", label: String(localized: "Trash"))
    /// Workspace numbers, right of Start.
    let workspaceNumbers = WorkspaceNumbersView()
    /// Line between the pinned apps and the others.
    private let separator = NSView()
    static let separatorGap = CGFloat(TaskbarModel.Widths().separator)
    /// Icons per app key (bundle ID or pid:n).
    private var icons: [String: NSImage] = [:]
    /// Set by the controller.
    var actions = TaskbarButton.Actions()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        overflowLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        overflowLabel.textColor = .secondaryLabelColor
        for view in [startButton, workspaceNumbers, entries, overflowLabel, trashButton] { background.addSubview(view) }
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.isHidden = true
        entries.addSubview(separator)
    }

    /// Bottom of the screen's usable area (above the Dock while it is still
    /// there), full width. `frame` and `visible` are AppKit rects.
    func place(on screen: NSScreen) {
        let v = Screens.usableArea(of: screen)
        panel.setFrame(NSRect(x: v.minX, y: v.minY, width: v.width, height: Self.height), display: false)
        layoutChrome()
    }

    /// Width left for entries, in points.
    var entriesWidth: Double { Double(entries.frame.width) }

    private func layoutChrome() {
        let bounds = background.bounds
        // No clock: the menu bar shows the time already.
        let side: CGFloat = 44
        startButton.frame = NSRect(x: 6, y: 3, width: side - 4, height: bounds.height - 6)
        trashButton.frame = NSRect(x: bounds.maxX - side - 2, y: 3, width: side - 4, height: bounds.height - 6)
        overflowLabel.frame = NSRect(x: trashButton.frame.minX - 40, y: 12, width: 36, height: 16)
        let numbersWidth = workspaceNumbers.preferredWidth
        workspaceNumbers.frame = NSRect(
            x: startButton.frame.maxX + (numbersWidth > 0 ? 4 : 0), y: 0, width: numbersWidth, height: bounds.height)
        let left = numbersWidth > 0 ? workspaceNumbers.frame.maxX : startButton.frame.maxX
        entries.frame = NSRect(x: left + 8, y: 0, width: overflowLabel.frame.minX - left - 12, height: bounds.height)
    }

    /// Shows the workspace numbers; true if they changed. A different count
    /// changes the room left for entries: the caller then redraws them.
    @discardableResult
    func showWorkspaces(_ items: [WorkspaceIndicator.Item]) -> Bool {
        let countChanged = items.count != workspaceNumbers.items.count
        guard workspaceNumbers.show(items) else { return false }
        if countChanged {
            layoutChrome()
            let current = shown
            shown = []
            show(current, overflow: Int(overflowLabel.stringValue.dropFirst()) ?? 0)
        }
        return true
    }

    /// Shows `items`; returns false when nothing changed (no redraw at all).
    /// Icons loaded during the last `show` (cache misses) and the time they took.
    private(set) var iconLoads = (count: 0, ms: 0.0)

    @discardableResult
    func show(_ items: [TaskbarItem], overflow: Int) -> Bool {
        overflowLabel.stringValue = overflow > 0 ? "+\(overflow)" : ""
        iconLoads = (0, 0)
        guard items != shown else { return false }
        shown = items
        // Window entries share the width left by icon-only entries (pinned, groups).
        let icons = items.filter { if case .window = $0.kind { false } else { true } }.count
        let windows = items.count - icons
        let widths = TaskbarModel.Widths()
        // Pinned apps come first: a line sets them apart from the others.
        let pinnedCount = items.prefix { $0.isPinned }.count
        let hasSeparator = pinnedCount > 0 && pinnedCount < items.count
        let free = max(0, entriesWidth - Double(icons) * widths.icon - (hasSeparator ? widths.separator : 0))
        let windowWidth =
            windows == 0 ? widths.window : min(widths.window, max(widths.minWindow, free / Double(windows)))
        while buttons.count < items.count {
            let button = TaskbarButton()
            button.actions = actions
            buttons.append(button)
            entries.addSubview(button)
        }
        var x: CGFloat = 0
        separator.isHidden = !hasSeparator
        for (index, button) in buttons.enumerated() {
            guard index < items.count else {
                button.isHidden = true
                continue
            }
            if hasSeparator, index == pinnedCount {
                separator.frame = NSRect(
                    x: x + Self.separatorGap / 2 - 3, y: 9, width: 1, height: TaskbarPanel.height - 18)
                x += Self.separatorGap
            }
            let item = items[index]
            let width: CGFloat
            if case .window = item.kind { width = CGFloat(windowWidth) } else { width = CGFloat(widths.icon) }
            button.isHidden = false
            button.frame = NSRect(x: x, y: 3, width: width - 4, height: TaskbarPanel.height - 6)
            button.configure(item, icon: icon(for: item))
            x += width
        }
        return true
    }

    private func icon(for item: TaskbarItem) -> NSImage {
        if let cached = icons[item.app] { return cached }
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer {
            iconLoads = (
                iconLoads.count + 1, iconLoads.ms + Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000_000
            )
        }
        var image: NSImage?
        if let pid = item.pid { image = NSRunningApplication(processIdentifier: pid)?.icon }
        if image == nil, !item.app.hasPrefix("pid:"),
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.app)
        {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        let result = image ?? NSImage(named: NSImage.applicationIconName)!
        icons[item.app] = result
        return result
    }

    /// An app quit: its icon may change at next launch.
    func forgetIcon(_ app: String) { icons[app] = nil }
}

/// One entry: icon, title (window entries), count (groups), active / dimmed look.
/// Clicks, right clicks and dropped files go to `actions`.
@MainActor
final class TaskbarButton: NSView {
    struct Actions {
        var click: (TaskbarItem, NSView) -> Void = { _, _ in }
        var rightClick: (TaskbarItem, NSEvent, NSView) -> Void = { _, _, _ in }
        /// Files dropped on the entry: open them with its app. Returns success.
        var drop: (TaskbarItem, [URL]) -> Bool = { _, _ in false }
        /// Files held over a window entry for a moment: bring it to the front
        /// so they can be dropped into it (Windows does the same).
        var dragHover: (TaskbarItem) -> Void = { _ in }
        /// The cursor entered (true) or left (false) the entry: shows or hides its previews.
        var hover: (TaskbarItem, NSView, Bool) -> Void = { _, _, _ in }
    }

    var actions = Actions()
    private var pressed = false
    private var hovered = false
    private var hoverTimer: Timer?

    private let iconView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let indicator = NSView()
    private let badge = NSTextField(labelWithString: "")
    private(set) var item: TaskbarItem?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        iconView.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        count.font = .systemFont(ofSize: 9, weight: .bold)
        count.alignment = .center
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1.5
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 7
        for view in [iconView, title, count, indicator, badge] { addSubview(view) }
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Hover highlight: tracked even though the panel is never key.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateBackground()
        if let item { actions.hover(item, self, true) }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateBackground()
        if let item { actions.hover(item, self, false) }
    }

    private func updateBackground() {
        let active = item?.isActive ?? false
        let alpha: CGFloat = active ? (hovered ? 0.16 : 0.10) : (hovered ? 0.08 : 0)
        layer?.backgroundColor = alpha > 0 ? NSColor.labelColor.withAlphaComponent(alpha).cgColor : nil
    }

    // The panel never becomes key: take the first click directly.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        layer?.opacity = 0.7
    }

    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1
        guard pressed, let item, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            pressed = false
            return
        }
        pressed = false
        actions.click(item, self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let item else { return }
        actions.rightClick(item, event, self)
    }

    override func otherMouseUp(with event: NSEvent) {}  // middle click: new window, not done yet

    // MARK: Files dropped on the entry

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let item, !fileURLs(sender).isEmpty else { return [] }
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        if case .window = item.kind {
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let item = self.item else { return }
                    self.actions.dragHover(item)
                }
            }
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endDrag() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        endDrag()
        guard let item else { return false }
        let urls = fileURLs(sender)
        return !urls.isEmpty && actions.drop(item, urls)
    }

    private func endDrag() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        layer?.borderWidth = 0
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
    }

    func configure(_ item: TaskbarItem, icon: NSImage) {
        let changed = item != self.item
        self.item = item
        if iconView.image !== icon { iconView.image = icon }
        guard changed || title.frame.width != max(0, bounds.width - 34) else { return }
        let isWindow: Bool
        if case .window = item.kind { isWindow = true } else { isWindow = false }
        let h = bounds.height
        iconView.frame =
            isWindow
            ? NSRect(x: 6, y: (h - 20) / 2, width: 20, height: 20)
            : NSRect(x: (bounds.width - 22) / 2, y: (h - 22) / 2, width: 22, height: 22)
        title.isHidden = !isWindow
        title.stringValue = isWindow ? (item.title?.isEmpty == false ? item.title! : (item.appName ?? "")) : ""
        title.frame = NSRect(x: 30, y: (h - 16) / 2, width: max(0, bounds.width - 34), height: 16)
        let windows = item.windowIDs.count
        count.isHidden = !(windows > 1)
        count.stringValue = "\(windows)"
        count.frame = NSRect(x: bounds.width - 16, y: h - 14, width: 14, height: 12)
        alphaValue = item.isDimmed ? 0.5 : 1
        // Dock badge, on the icon's top-right corner.
        badge.isHidden = item.badge == nil
        if let text = item.badge {
            badge.stringValue = text.count > 3 ? "…" : text
            let width = max(14, CGFloat(badge.stringValue.count) * 7 + 6)
            badge.frame = NSRect(
                x: iconView.frame.maxX - width / 2, y: iconView.frame.maxY - 9, width: width, height: 14)
        }
        // Running apps get a small bar under them, the active entry a highlight.
        let running = !item.windowIDs.isEmpty
        indicator.isHidden = !running
        let barWidth: CGFloat = item.isActive ? min(bounds.width - 12, 24) : 8
        indicator.frame = NSRect(x: (bounds.width - barWidth) / 2, y: 1, width: barWidth, height: 3)
        indicator.layer?.backgroundColor =
            (item.isActive ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor
        updateBackground()
        toolTip = nil  // the hover preview replaces tooltips
    }
}

/// A fixed icon of the bar (Start, Trash): hover highlight, click, right click.
@MainActor
final class BarIconButton: NSView {
    private let iconView = NSImageView()
    private var hovered = false
    var onClick: (NSView) -> Void = { _ in }
    var onRightClick: (NSEvent, NSView) -> Void = { _, _ in }

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .labelColor
        setSymbol(symbol, label: label)
        addSubview(iconView)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setSymbol(_ symbol: String, label: String) {
        iconView.contentTintColor = .labelColor
        iconSide = 22
        needsLayout = true
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(
            config)
    }

    /// A full-colour image (an app icon) instead of a symbol.
    func setImage(_ image: NSImage) {
        iconView.contentTintColor = nil
        iconView.image = image
        iconSide = 26
        needsLayout = true
    }

    private var iconSide: CGFloat = 22

    override func layout() {
        super.layout()
        iconView.frame = bounds.insetBy(dx: (bounds.width - iconSide) / 2, dy: (bounds.height - iconSide) / 2)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    private func setHover(_ on: Bool) {
        hovered = on
        layer?.backgroundColor = on ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick(self) }
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick(event, self) }
}

/// Workspace numbers of one bar: the visible one highlighted, a click switches,
/// the name (if any) as a tooltip.
@MainActor
final class WorkspaceNumbersView: NSView {
    static let side: CGFloat = 26
    private(set) var items: [WorkspaceIndicator.Item] = []
    private var labels: [NSView] = []
    var onPick: (Int) -> Void = { _ in }

    var preferredWidth: CGFloat { CGFloat(items.count) * Self.side }

    /// False when nothing changed.
    func show(_ new: [WorkspaceIndicator.Item]) -> Bool {
        guard new != items else { return false }
        items = new
        hover.hide()
        hovered = nil
        labels.forEach { $0.removeFromSuperview() }
        labels = new.enumerated().map { i, item in
            // A rounded square, the digit centred in it both ways: a label
            // alone draws its text at the top of its frame.
            let square = NSView(
                frame: NSRect(
                    x: CGFloat(i) * Self.side + 2, y: (TaskbarPanel.height - 22) / 2, width: Self.side - 4, height: 22))
            square.wantsLayer = true
            square.layer?.cornerRadius = 5
            square.layer?.backgroundColor =
                item.isVisible ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : nil
            square.setAccessibilityLabel(Self.hint(item))
            let label = Self.content(for: item, fitting: square.bounds.width - 4)
            let size = label.frame.size
            label.frame.origin = NSPoint(
                x: ((square.bounds.width - size.width) / 2).rounded(),
                y: ((square.bounds.height - size.height) / 2).rounded())
            square.addSubview(label)
            addSubview(square)
            return square
        }
        return true
    }

    /// The number, or the icon set in `workspaces.icons` (an unknown SF
    /// Symbol keeps the number). Sized to its content, at most `width` wide.
    private static func content(for item: WorkspaceIndicator.Item, fitting width: CGFloat) -> NSView {
        let color: NSColor = item.isVisible ? .labelColor : .secondaryLabelColor
        switch item.icon {
        case .symbol(let name)?:
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: item.isVisible ? .bold : .regular)
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
                config)
            {
                let view = NSImageView(image: image)
                view.contentTintColor = color
                let size = image.size
                let scale = min(1, width / max(size.width, 1), 16 / max(size.height, 1))
                view.frame.size = NSSize(
                    width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
                view.imageScaling = .scaleProportionallyDown
                return view
            }
            if !reportedSymbols.contains(item.number) {
                reportedSymbols.insert(item.number)
                Log.info("taskbar: the icon of workspace \(item.number) is no SF Symbol, its number is shown")
            }
        case .text(let text)?:
            // Emoji keep their colours; letters follow the bar's.
            var size: CGFloat = 14
            let label = NSTextField(labelWithString: text)
            label.textColor = color
            repeat {
                label.font = .systemFont(ofSize: size, weight: item.isVisible ? .bold : .regular)
                label.sizeToFit()
                size -= 1
            } while label.frame.width > width && size >= 8
            return label
        case nil:
            break
        }
        let label = NSTextField(labelWithString: "\(item.number)")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: item.isVisible ? .bold : .regular)
        label.textColor = color
        label.sizeToFit()
        return label
    }

    /// Workspaces whose unknown symbol was logged (once each).
    private static var reportedSymbols: Set<Int> = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        hover.hide()
        let x = convert(event.locationInWindow, from: nil).x
        let index = Int(x / Self.side)
        if items.indices.contains(index) { onPick(items[index].number) }
    }

    // MARK: Hover label
    // AppKit tooltips never show here: Pavé is never the active app and the
    // bar is a non-activating panel. Pavé draws its own label instead.

    private let hover = HoverLabel()
    private var hovered: Int?
    private var hoverTimer: Timer?

    static func hint(_ item: WorkspaceIndicator.Item) -> String {
        item.name.map { "\(item.number) · \($0)" } ?? String(localized: "Workspace \(item.number)")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        )
    }

    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
        hovered = nil
        hover.hide()
    }

    private func track(_ event: NSEvent) {
        let index = Int(convert(event.locationInWindow, from: nil).x / Self.side)
        guard items.indices.contains(index) else { return mouseExited(with: event) }
        guard index != hovered else { return }
        hovered = index
        hoverTimer?.invalidate()
        if hover.isVisible {
            showHover(index)  // moving along the numbers: follow at once
        } else {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showHover(index) }
            }
        }
    }

    private func showHover(_ index: Int) {
        guard items.indices.contains(index), index == hovered, index < labels.count, let window else { return }
        let square = labels[index]
        hover.show(Self.hint(items[index]), above: window.convertToScreen(square.convert(square.bounds, to: nil)))
    }
}

/// A small label above the bar, like a tooltip; never takes the focus.
@MainActor
final class HoverLabel {
    private let panel: NSPanel
    private let text = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        background.addSubview(text)
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    /// `anchor`: the hovered square, in screen coordinates.
    func show(_ string: String, above anchor: NSRect) {
        text.stringValue = string
        text.sizeToFit()
        let size = NSSize(width: text.frame.width + 16, height: text.frame.height + 8)
        text.frame.origin = NSPoint(x: 8, y: 4)
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            origin.x = min(max(origin.x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

/// The bar's background: a right click on an empty part (or bubbling up from
/// the entries area) shows the bar's menu.
@MainActor
final class BarBackground: NSVisualEffectView {
    var onRightClick: (NSEvent, NSView) -> Void = { _, _ in }
    override func rightMouseDown(with event: NSEvent) { onRightClick(event, self) }
}
