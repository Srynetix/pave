// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// Runs one TaskbarPanel per screen, fed by the registry.
///
/// No AX call here: everything comes from the registry's last snapshot,
/// so an update costs the model plus redrawing what changed. Each update is
/// timed from the registry event to the panels drawn, and logged as a running
/// p50 / p95 every 25 updates.
@MainActor
public final class TaskbarController {
    public struct Settings: Equatable, Sendable {
        public var enabled: Bool
        public var grouping: TaskbarGrouping
        public var pinned: [String]
        public var hideDock: Bool
        public init(enabled: Bool, grouping: TaskbarGrouping, pinned: [String], hideDock: Bool = false) {
            self.enabled = enabled
            self.grouping = grouping
            self.pinned = pinned
            self.hideDock = hideDock
        }
    }

    let registry: WindowRegistry
    let focusService: FocusService
    let thumbnails: ThumbnailService
    let dock: DockController
    let badges = DockBadges()
    /// App rule of a window (taskbar-overlap), from the config.
    let rule: (WindowSnapshot) -> AppRule
    var overlapChecks: [WindowID: DispatchWorkItem] = [:]
    var overlapFixes: [WindowID: [Date]] = [:]
    var overlapTimes = Samples()
    var overlapResults = (ok: 0, miss: 0)
    let preview = TaskbarPreview()
    let launcher = LauncherPanel()
    var trashTimer: Timer?
    var trashEmpty: Bool??
    var showTimer: Timer?
    var hideTimer: Timer?
    var liveTimer: Timer?
    var previewTimes = Samples()
    var previewHits = (cached: 0, total: 0)
    /// Hover delay before the first preview; moving to another entry then is immediate.
    static let hoverDelay: TimeInterval = 0.4
    static let hideDelay: TimeInterval = 0.3
    /// While a preview is up, its windows are captured again this often.
    static let liveInterval: TimeInterval = 1
    /// Writes `taskbar.pinned` to the config (it stays the source of truth).
    let setPinned: ([String]) -> Void
    let bundleID: (PID) -> String?
    /// Parked, or of a workspace shown on no screen (minimized): not listed.
    let isOutOfSight: (WindowID) -> Bool
    /// Workspace numbers of the bar on a screen; empty when workspaces are off.
    public var workspaceIndicator: (Screen) -> [WorkspaceIndicator.Item] = { _ in [] }
    public var switchWorkspace: (Int) -> Void = { _ in }
    /// Workspace of a window (nil when workspaces are off), names from the
    /// config (menu labels only, never logged), and the move itself.
    public var workspaceOf: (WindowID) -> Int? = { _ in nil }
    public var workspaceNames: () -> [String] = { [] }
    public var moveToWorkspace: ([WindowID], Int) -> Void = { _, _ in }
    /// "Pin to Workspace": workspaces are on, the app rule of a bundle ID,
    /// writing its `workspace` (nil: removed), and its rule in Settings.
    public var workspacesEnabled: () -> Bool = { false }
    public var appRule: (String) -> AppRule = { _ in AppRule() }
    public var pinToWorkspace: (String, Int?) -> Void = { _, _ in }
    public var editAppRule: (String) -> Void = { _ in }
    /// A title rule `pattern = N` or `"all"` for an app (never logged: part of a title).
    public var pinWindowTitle: (String, String, TitleTarget) -> Void = { _, _, _ in }
    /// "Show on All Workspaces": whether a window is, and the change.
    public var isEverywhere: (WindowID) -> Bool = { _ in false }
    public var setEverywhere: (WindowID, Bool) -> Void = { _, _ in }
    /// Tiled windows are kept in the usable area by the tiling: not corrected here.
    public var isTiled: (WindowID) -> Bool = { _ in false }
    var settings: Settings
    var model = TaskbarModel()
    var panels: [CGDirectDisplayID: TaskbarPanel] = [:]
    var observers: [NSObjectProtocol] = []
    var updateTimes = Samples()
    let trashQueue = DispatchQueue(label: "pave.trash")
    var trashObserver: NSObjectProtocol?
    var finderWasFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    weak var previewAnchor: TaskbarButton?

    public init(
        registry: WindowRegistry, focus: FocusService, thumbnails: ThumbnailService, dock: DockController,
        settings: Settings, bundleID: @escaping (PID) -> String?, rule: @escaping (WindowSnapshot) -> AppRule,
        isOutOfSight: @escaping (WindowID) -> Bool, setPinned: @escaping ([String]) -> Void
    ) {
        self.dock = dock
        self.rule = rule
        self.registry = registry
        self.focusService = focus
        self.thumbnails = thumbnails
        self.setPinned = setPinned
        self.settings = settings
        self.bundleID = bundleID
        self.isOutOfSight = isOutOfSight
        registry.addChangeObserver { [weak self] changes in
            self?.refresh(reason: "registry")
            self?.watchOverlaps(changes)
        }
        badges.onChange = { [weak self] in self?.refresh(reason: "badges") }
        focus.addWillFocusObserver { [weak self] window in self?.willFocus(window) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refreshAfterTransition(reason: "activation") }
            })
        // Entering or leaving a full-screen Space.
        observers.append(
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refreshAfterTransition(reason: "space") }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.rebuildPanels() } })
        thumbnails.addUpdateObserver { [weak self] id, image in self?.preview.update(id, image) }
        preview.onPick = { [weak self] id in
            guard let self, let window = self.registry.store.windows[id] else { return }
            self.hidePreview()
            self.focus(window, how: "preview")
        }
        preview.onClose = { [weak self] id in
            guard let self, let window = self.registry.store.windows[id] else { return }
            self.registry.close(window) { ok in
                Log.info("taskbar: close \(id) [\(window.appName)] from preview \(ok ? "requested" : "FAILED")")
            }
        }
        preview.onHover = { [weak self] inside in
            guard let self else { return }
            if inside { self.hideTimer?.invalidate() } else { self.scheduleHide() }
        }
        dock.onHiddenAgain = { [weak self] in self?.replaceAfterDockRestart() }
        if settings.enabled { start() } else { dock.apply(hidden: false) }  // a crash may have left it hidden
    }

    public func update(settings new: Settings) {
        guard new != settings else { return }
        let wasEnabled = settings.enabled
        settings = new
        if new.enabled && !wasEnabled {
            start()
        } else if !new.enabled && wasEnabled {
            stop()
        } else {
            applyDock()
            refresh(reason: "config")
        }
    }

    /// Dock hidden only while the bar is there to replace it.
    func applyDock() {
        let wanted = settings.enabled && settings.hideDock
        // Hidden for good: its reserved space (if macOS keeps one) is used anyway.
        Screens.ignoresDockReserve = wanted
        let changes = wanted != dock.isHiddenByPave
        dock.apply(hidden: wanted)
        guard changes else { return }
        replaceAfterDockRestart()
    }

    /// The usable area changes once the Dock has restarted, which may take a
    /// few seconds: place the bars again after 1 s, and once more after 3 s.
    func replaceAfterDockRestart() {
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.rebuildPanels()
                    if delay == 3.0 { self?.checkDockReserve() }
                }
            }
        }
    }

    /// Once hidden, the Dock must not reserve space at the bottom any more
    /// (a few points at most): else the bars float above an empty band.
    func checkDockReserve() {
        guard settings.enabled, settings.hideDock, dock.isHiddenByPave else { return }
        // Bottom or sides: the Dock sits on the left while hidden.
        let reserve =
            NSScreen.screens.map { s in
                let v = s.visibleFrame
                let f = s.frame
                return max(v.minY - f.minY, v.minX - f.minX, f.maxX - v.maxX)
            }.max() ?? 0
        if reserve > 10 {
            dock.rehideFully(reason: "hidden but still reserving \(Int(reserve)) pt (ignored)")
        } else {
            dock.reserveIsFine()
            Log.info("dock: hidden, reserve \(Int(reserve)) pt")
        }
    }

    /// "Reset Taskbar": the Dock restarted hidden (when it hides),
    /// the bars put back at the bottom of each screen.
    public func reset() {
        guard settings.enabled else { return }
        Log.info("taskbar: reset")
        hidePreview()
        launcher.hide()
        if settings.hideDock && dock.isHiddenByPave {
            dock.rehideFully(reason: "taskbar reset", force: true)  // then places the bars again
        } else {
            applyDock()
        }
        rebuildPanels()
    }

    public var isOn: Bool { settings.enabled }

    func start() {
        Screens.taskbarHeight = Double(TaskbarPanel.height)
        applyDock()
        badges.start()
        rebuildPanels()
        scheduleTrashCheck()
        trashObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let finder = app?.bundleIdentifier == "com.apple.finder"
            MainActor.assumeIsolated {
                guard let self, self.trashTimer != nil else { return }
                // Leaving the Finder: something may just have been deleted.
                if self.finderWasFrontmost && !finder { self.updateTrash() }
                self.finderWasFrontmost = finder
                self.scheduleTrashCheck()
            }
        }
        preview.prewarm()
        Log.info(
            "taskbar: on, \(panels.count) screen(s), grouping \(settings.grouping.rawValue), \(settings.pinned.count) pinned"
        )
    }

    func stop() {
        hidePreview()
        launcher.hide()
        trashTimer?.invalidate()
        trashTimer = nil
        if let trashObserver { NSWorkspace.shared.notificationCenter.removeObserver(trashObserver) }
        trashObserver = nil
        badges.stop()
        Screens.taskbarHeight = 0
        Screens.ignoresDockReserve = false
        dock.apply(hidden: false)
        panels.values.forEach { $0.panel.orderOut(nil) }
        panels = [:]
        Log.info("taskbar: off")
    }

    func rebuildPanels() {
        guard settings.enabled else { return }
        var kept: [CGDirectDisplayID: TaskbarPanel] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let panel = panels[id] ?? makePanel()
            panel.place(on: screen)
            panel.panel.orderFrontRegardless()
            kept[id] = panel
        }
        for (id, panel) in panels where kept[id] == nil { panel.panel.orderOut(nil) }
        panels = kept
        trashEmpty = nil
        updateTrash()
        refresh(reason: "screens")
    }

    // MARK: - Updates

    /// Space changes are announced before their animation ends: the window
    /// server shows the new Space's windows a little later. Look again then.
    /// Polls the visibility only (≈ 0.3 ms each) every 50 ms for 1.2 s:
    /// catches the Space as soon as the window server shows it.
    func refreshAfterTransition(reason: String) {
        refresh(reason: reason)
        burstUntil = Date().addingTimeInterval(1.2)
        guard burstTimer == nil else { return }
        burstTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard Date() < self.burstUntil else {
                    self.burstTimer?.invalidate()
                    self.burstTimer = nil
                    return
                }
                self.updateFullScreenVisibility()
            }
        }
    }

    var burstTimer: Timer?
    var anticipated: [CGDirectDisplayID: (visible: Bool, until: Date)] = [:]
    var burstUntil = Date.distantPast

    /// A window is about to be focused (switcher, bar, preview): hide or show
    /// the bar of its screen right away, without waiting for the Space change.
    func willFocus(_ window: WindowSnapshot) {
        guard settings.enabled, let id = Self.screenID(of: window.frame), let panel = panels[id] else { return }
        let visible = window.state != .fullscreen
        setVisible(panel, visible)
        // Hold it through the Space animation: the window server only shows
        // the target's Space a moment later.
        anticipated[id] = (visible, Date().addingTimeInterval(0.8))
        refreshAfterTransition(reason: "focus")
    }

    static func screenID(of frame: Rect) -> CGDirectDisplayID? {
        NSScreen.screens.max(by: {
            Screens.axFrame($0).intersectionArea(with: frame) < Screens.axFrame($1).intersectionArea(with: frame)
        })?.displayID
    }

    func setVisible(_ panel: TaskbarPanel, _ visible: Bool) {
        if !visible, panel.panel.isVisible {
            panel.panel.orderOut(nil)
            hidePreview()
            launcher.hide()
        } else if visible, !panel.panel.isVisible {
            panel.panel.orderFrontRegardless()
        }
    }

    /// The bar stays out of a screen showing a native full-screen window (it
    /// joins every Space, full-screen ones included). "Showing": on screen now
    /// for the window server, so we are in that window's Space. Not "the
    /// focused window": an app may have several processes (Prism).
    func updateFullScreenVisibility() {
        guard settings.enabled else { return }
        var fullScreen: Set<CGDirectDisplayID> = []
        let candidates = registry.store.windows.values.filter { $0.state == .fullscreen }
        if !candidates.isEmpty {
            let onScreen = Self.onScreenWindowIDs()
            for window in candidates where onScreen.contains(window.id) {
                if let id = Self.screenID(of: window.frame) { fullScreen.insert(id) }
            }
        }
        for (id, panel) in panels {
            if let held = anticipated[id] {
                if Date() < held.until, held.visible == fullScreen.contains(id) { continue }  // not there yet
                anticipated[id] = nil
            }
            setVisible(panel, !fullScreen.contains(id))
        }
    }

    /// The workspaces changed (switch, move, screens): numbers and entries.
    public func workspacesChanged() { refresh(reason: "workspaces") }

    func refresh(reason: String) {
        guard settings.enabled, !panels.isEmpty else { return }
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        // Where the time goes, for the slow updates (T1 p95 reached 200+ ms).
        var phases: [(String, Double)] = []
        var mark = start
        func lap(_ name: String) {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let i = phases.firstIndex(where: { $0.0 == name }) {
                phases[i].1 += Double(now - mark) / 1_000_000
            } else {
                phases.append((name, Double(now - mark) / 1_000_000))
            }
            mark = now
        }
        let windows = Array(registry.store.windows.values)
        model.update(windows: windows)
        let screens = Screens.all()
        let active = registry.focusedWindow?.id
        var bundles: [PID: String] = [:]
        for pid in Set(windows.map(\.pid)) { bundles[pid] = bundleID(pid) }
        let parked = Set(windows.map(\.id).filter(isOutOfSight))
        lap("inputs")
        updateFullScreenVisibility()
        lap("fullscreen")
        var changed = false
        var icons = (count: 0, ms: 0.0)
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let panel = panels[id],
                let axScreen = screens.first(where: { Screens.appKit($0.frame) == screen.frame })
            else { continue }
            // Workspace numbers first: they change the width left for the entries.
            if panel.showWorkspaces(workspaceIndicator(axScreen)) { changed = true }
            var (items, overflow) = model.items(
                windows: windows, on: axScreen, screens: screens, active: active, bundleIDs: bundles,
                pinned: settings.pinned, grouping: settings.grouping, width: panel.entriesWidth, hidden: parked)
            var badged: Set<String> = []
            for index in items.indices where !badged.contains(items[index].app) {
                badged.insert(items[index].app)
                items[index].badge = badges.badges[items[index].app]
            }
            lap("model")
            if panel.show(items, overflow: overflow) { changed = true }
            icons = (icons.count + panel.iconLoads.count, icons.ms + panel.iconLoads.ms)
            lap("views")
        }
        // A previewed window closed or another opened: keep the preview in step.
        if preview.isVisible, let anchor = previewAnchor, let item = anchor.item {
            let ids = item.windowIDs.filter { registry.store.windows[$0] != nil }
            if ids.isEmpty { hidePreview() } else if ids != preview.windowIDs { showPreview(item, anchor: anchor) }
        }
        lap("preview")
        guard changed else { return }
        CATransaction.flush()
        lap("flush")
        let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000_000
        if ms >= Self.slowUpdate {
            let detail = phases.filter { $0.1 >= 1 }.map { "\($0.0) \(Int($0.1))" }.joined(separator: ", ")
            Log.info(
                "taskbar slow update (\(reason)): \(Int(ms)) ms (\(detail); icons loaded \(icons.count) in \(Int(icons.ms)) ms)"
            )
        }
        updateTimes.append(ms)
        if updateTimes.count % 25 == 0 {
            let sorted = updateTimes.sorted()
            Log.info(
                "taskbar (T1): n=\(sorted.count) updates, p50 \(String(format: "%.1f", sorted[sorted.count / 2])) ms, "
                    + "p95 \(String(format: "%.1f", sorted[Int(Double(sorted.count) * 0.95)])) ms, max \(String(format: "%.1f", sorted.last!)) ms"
            )
        }
    }

    /// An update slower than this is logged with where its time went.
    static let slowUpdate: Double = 50

    /// Windows the window server shows right now (current Spaces), IDs only.
    static func onScreenWindowIDs() -> Set<WindowID> {
        let list =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? UInt32).map { WindowID($0) } })
    }

    /// The Start key (left ⌥ tapped alone): toggles the launcher, above the
    /// Start button of the screen under the cursor.
    public func toggleLauncher() {
        guard settings.enabled else { return }
        if launcher.isVisible { return launcher.hide() }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        // No launcher where the bar is hidden (full screen).
        guard let id = screen?.displayID ?? NSScreen.screens.first?.displayID,
            let panel = panels[id] ?? panels.values.first,
            panel.panel.isVisible
        else { return }
        hidePreview()
        launcher.show(above: panel.startButton)
    }

    // MARK: - Actions

    func makePanel() -> TaskbarPanel {
        let panel = TaskbarPanel()
        panel.startButton.onClick = { [weak self] view in
            guard let self else { return }
            self.hidePreview()
            if self.launcher.isVisible { self.launcher.hide() } else { self.launcher.show(above: view) }
        }
        panel.trashButton.onClick = { _ in Trash.open() }
        // Right click on Start or on an empty part of the bar.
        let barMenu: (NSEvent, NSView) -> Void = { [weak self] event, view in
            let menu = NSMenu()
            menu.addItem(
                ClosureMenuItem(NSMenuItem(title: String(localized: "Reset Taskbar"), action: nil, keyEquivalent: "")) {
                    self?.reset()
                })
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        panel.startButton.onRightClick = barMenu
        panel.onRightClick = barMenu
        panel.workspaceNumbers.onPick = { [weak self] n in self?.switchWorkspace(n) }
        panel.trashButton.onRightClick = { [weak self] event, view in
            let menu = NSMenu()
            menu.addItem(
                ClosureMenuItem(NSMenuItem(title: String(localized: "Open Trash"), action: nil, keyEquivalent: "")) {
                    Trash.open()
                })
            let empty = ClosureMenuItem(
                NSMenuItem(title: String(localized: "Empty Trash…"), action: nil, keyEquivalent: "")
            ) {
                Trash.emptyAfterConfirmation { _ in self?.updateTrash() }
            }
            // Known to be empty: nothing to do.
            if self?.trashEmpty == .some(true) {
                empty.isEnabled = false
                menu.autoenablesItems = false
            }
            menu.addItem(empty)
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        panel.actions = TaskbarButton.Actions(
            click: { [weak self] item, view in self?.click(item, from: view) },
            rightClick: { [weak self] item, event, view in self?.contextMenu(item, event: event, view: view) },
            drop: { [weak self] item, urls in self?.open(urls, with: item) ?? false },
            dragHover: { [weak self] item in
                if let id = item.windowIDs.first, let w = self?.registry.store.windows[id] {
                    self?.focus(w, how: "file hover")
                }
            },
            hover: { [weak self] item, view, inside in self?.hover(item, view: view, inside: inside) })
        return panel
    }

    func click(_ item: TaskbarItem, from view: NSView) {
        let windows = item.windowIDs.compactMap { registry.store.windows[$0] }
        if windows.count > 1, let button = view as? TaskbarButton {
            // A group: its previews, right away, to pick a window.
            showTimer?.invalidate()
            return showPreview(item, anchor: button)
        }
        hidePreview()
        switch windows.count {
        case 0:
            launch(item)
        case 1:
            let window = windows[0]
            // Windows: clicking the active window's entry minimizes it.
            if item.isActive, window.state == .normal {
                registry.minimize(window) { ok in
                    Log.info("taskbar: minimize \(window.id) [\(window.appName)] \(ok ? "ok" : "FAILED")")
                }
            } else {
                focus(window, how: "click")
            }
        default:
            // A group: pick one of its windows.
            let menu = NSMenu()
            let mru = registry.store.orderedWindows.map(\.id)
            for window in windows.sorted(by: {
                (mru.firstIndex(of: $0.id) ?? .max) < (mru.firstIndex(of: $1.id) ?? .max)
            }) {
                let entry = NSMenuItem(
                    title: window.title.isEmpty ? window.appName : window.title, action: nil, keyEquivalent: "")
                entry.state = window.id == registry.focusedWindow?.id ? .on : .off
                menu.addItem(ClosureMenuItem(entry) { [weak self] in self?.focus(window, how: "group menu") })
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
    }

    func focus(_ window: WindowSnapshot, how: String) {
        focusService.focus(window, source: "taskbar \(how)")
    }

    func launch(_ item: TaskbarItem) {
        guard let url = appURL(item) else { return Log.info("taskbar: no app found for \(item.app)") }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Log.info("taskbar: launch \(item.app) " + (error.map { "FAILED (\($0.localizedDescription))" } ?? "ok"))
        }
    }

    func appURL(_ item: TaskbarItem) -> URL? {
        if let pid = item.pid, let url = NSRunningApplication(processIdentifier: pid)?.bundleURL { return url }
        guard !item.app.hasPrefix("pid:") else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.app)
    }

    /// Files dropped on an entry open with its app, as on the Dock.
    func open(_ urls: [URL], with item: TaskbarItem) -> Bool {
        guard let app = appURL(item) else { return false }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            Log.info(
                "taskbar: \(urls.count) file(s) opened with \(item.app) "
                    + (error.map { "FAILED (\($0.localizedDescription))" } ?? "ok"))
        }
        return true
    }

}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }
}

/// A menu item that runs a closure (no target/selector plumbing).
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ template: NSMenuItem, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: template.title, action: #selector(run), keyEquivalent: "")
        state = template.state
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc func run() { handler() }
}
