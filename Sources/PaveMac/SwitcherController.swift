// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// Runs switcher sessions: turns the keys of the event tap into a
/// `SwitcherSession` and performs its effects (focus, close, quit).
///
/// Every change is logged, titles redacted as usual, and reported to `onChange`.
@MainActor
public final class SwitcherController {
    public private(set) var session: SwitcherSession?
    /// Called with the session after every change.
    public var onChange: ((SwitcherSession?) -> Void)?

    private let registry: WindowRegistry
    private let workspaces: WorkspaceController
    private let focusService: FocusService
    private let config: () -> PaveConfig
    private let endTapSession: (Int) -> Void
    private var tapSession = 0
    private var openedAt: UInt64 = 0
    private let panel = SwitcherPanel()
    private let thumbnails: ThumbnailService
    /// Display latency: how long the panel took to appear, every session (p50 / p95 in the logs).
    private var displayLatencies: [Double] = []

    public init(
        registry: WindowRegistry, workspaces: WorkspaceController, focus: FocusService,
        thumbnails: ThumbnailService, config: @escaping () -> PaveConfig, endTapSession: @escaping (Int) -> Void
    ) {
        self.thumbnails = thumbnails
        self.registry = registry
        self.focusService = focus
        self.workspaces = workspaces
        self.config = config
        self.endTapSession = endTapSession
        registry.addChangeObserver { [weak self] _ in self?.registryChanged() }
        panel.onPick = { [weak self] id in self?.pick(id) }
        panel.previewFor = { [weak self] id in self?.thumbnails.cached(id) }
        thumbnails.addUpdateObserver { [weak self] id, image in self?.panel.updatePreview(id, image) }
        registry.addChangeObserver { [weak self] changes in
            guard let self else { return }
            for change in changes {
                switch change {
                case .destroyed(let window): self.thumbnails.forget(window.id)
                case .focused(let id):
                    // The window the user just left: what they saw last, worth keeping.
                    if let left = self.lastFocused, left != id, self.registry.store.windows[left]?.state == .normal {
                        self.thumbnails.captureLater([left])
                    }
                    self.lastFocused = id
                default: break
                }
            }
        }
    }

    private var lastFocused: WindowID?

    /// Asks for Screen Recording once, at start-up rather than mid-switch.
    public func requestPreviewPermission() {
        thumbnails.requestPermissionIfNeeded()
        // Start-up fill, in the background, one window at a time.
        let windows = registry.store.orderedWindows.filter { $0.state == .normal }.map(\.id)
        thumbnails.captureLater(windows)
        lastFocused = registry.store.orderedWindows.first?.id
    }

    /// First display is slow (views, icons, HUD material: measured
    /// 1.85 s): do it once, invisibly, as soon as the windows are known.
    public func prewarm() {
        let start = Date()
        panel.prewarm(SwitcherSession(windows: registry.store.orderedWindows))
        Log.info("switcher panel prewarmed in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    /// A card was clicked.
    private func pick(_ id: WindowID) {
        guard var current = session else { return }
        current.select(id)
        finish(current.commit(), current, how: "click")
    }

    private func display(_ s: SwitcherSession?) {
        panel.show(s)
        onChange?(s)
    }

    public func handle(_ key: HotkeyService.SwitcherKey) {
        if case .open(let id, let sameApp, let backwards, let start) = key {
            tapSession = id
            return open(sameApp: sameApp, backwards: backwards, latencyStart: start)
        }
        guard var current = session else { return }
        switch key {
        case .open: return
        case .next, .right: current.next()
        case .previous, .left: current.previous()
        case .down: current.vertical(1, columns: panel.columns)
        case .up: current.vertical(-1, columns: panel.columns)
        case .enterSearch: current.enterSearch()
        case .type(let text): current.type(text)
        case .backspace: current.deleteBackward()
        case .close:
            if let effect = current.closeSelected() { perform(effect) }
        case .quit:
            if let effect = current.quitSelectedApp() { perform(effect) }
        case .commit, .released:
            return finish(current.commit(), current, how: key == .released ? "release" : "return")
        case .cancel:
            return finish(.dismiss, current, how: "cancel")
        case .mouseDown:
            // A click elsewhere ends the session; a click on a card is handled
            // by the card itself (it arrives right after this event).
            if !panel.contains(NSEvent.mouseLocation) { return finish(.dismiss, current, how: "click outside") }
            return
        }
        session = current
        log(current, event: "\(key)")
        display(current)
    }

    // MARK: - Session lifecycle

    /// Scope `screen`: the windows shown on the focused window's screen (else
    /// the one under the mouse), minimized ones of that screen included.
    private func windowsOnScreenInUse() -> Set<WindowID> {
        let screens = Screens.all()
        guard
            let screen = registry.focusedWindow.flatMap({ LayoutEngine.screen(for: $0.frame, among: screens) })
                ?? Screens.underMouse(among: screens)
        else { return [] }
        let state = workspaces.state
        return Set(
            registry.store.orderedWindows.filter { window in
                !state.isHidden(window.id) && LayoutEngine.screen(for: window.frame, among: screens) == screen
            }.map(\.id))
    }

    private func open(sameApp: Bool, backwards: Bool, latencyStart: UInt64) {
        let settings = config()
        let state = workspaces.state
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let options = SwitcherSession.Options(
            scope: settings.switcherScope,
            activeWorkspace: workspaces.isEnabled ? state.active : nil,
            workspaceOf: state.assignment,
            visibleWorkspaces: workspaces.isEnabled ? state.visibleWorkspaces : [],
            onlyApp: sameApp ? frontmost : nil,
            onScreen: settings.switcherScope == .screen ? windowsOnScreenInUse() : [])
        let new = SwitcherSession(windows: registry.store.orderedWindows, options: options, backwards: backwards)
        session = new
        openedAt = latencyStart
        let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - latencyStart) / 1_000_000
        Log.info(
            "switcher opened\(sameApp ? " (same app)" : "")\(backwards ? " backwards" : ""): "
                + "\(new.entries.count) window(s), model ready \(String(format: "%.1f", ms)) ms after the key")
        log(new, event: "open")
        // Display latency: the panel is on screen once Core Animation has committed it.
        CATransaction.begin()
        display(new)
        CATransaction.commit()
        CATransaction.flush()
        let shown = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - latencyStart) / 1_000_000
        // After the panel is up: previews never delay its appearance.
        thumbnails.switcherOpened(new.entries)
        displayLatencies.append(shown)
        let sorted = displayLatencies.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        Log.info(
            "switcher panel shown \(String(format: "%.1f", shown)) ms after the key "
                + "(S1 so far: n=\(sorted.count), p50 \(String(format: "%.1f", sorted[sorted.count / 2])), p95 \(String(format: "%.1f", p95)) ms)"
        )
    }

    private func finish(_ effect: SwitcherSession.Effect, _ last: SwitcherSession, how: String) {
        session = nil
        endTapSession(tapSession)
        display(nil)
        let held = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - openedAt) / 1_000_000_000
        switch effect {
        case .focus(let id, let rank):
            // Rank 1 = the previous window, what a quick ⌃Tab should give.
            let app = registry.store.windows[id]?.appName ?? "?"
            Log.info(
                "switcher → \(id) [\(app)] by \(how), MRU rank \(rank) of \(last.all.count), "
                    + "\(last.mode == .search ? "search" : "held"), open \(String(format: "%.1f", held)) s")
        default:
            Log.info("switcher dismissed by \(how)")
        }
        perform(effect)
    }

    /// A window opened or closed while the switcher is open.
    private func registryChanged() {
        guard var current = session else { return }
        current.update(windows: registry.store.orderedWindows)
        guard current != session else { return }
        session = current
        display(current)
    }

    // MARK: - Effects

    private func perform(_ effect: SwitcherSession.Effect) {
        switch effect {
        case .focus(let id, _):
            guard let window = registry.store.windows[id] else {
                return Log.info("switcher: \(id) is gone")
            }
            // A window of another workspace: the WorkspaceController follows the
            // focus change and switches.
            focusService.focus(window, source: "switcher")
        case .close(let id):
            guard let window = registry.store.windows[id] else { return }
            registry.close(window) { ok in
                Log.info("switcher: close \(id) [\(window.appName)] \(ok ? "requested" : "FAILED")")
            }
        case .quit(let pid):
            let app = NSRunningApplication(processIdentifier: pid)
            let ok = app?.terminate() ?? false
            Log.info("switcher: quit \(app?.localizedName ?? "pid \(pid)") \(ok ? "requested" : "FAILED")")
        case .dismiss:
            break
        }
    }

    // MARK: - Logs (no panel yet)

    private func log(_ s: SwitcherSession, event: String) {
        let shown = s.entries.prefix(8).enumerated().map { index, entry in
            let mark = index == s.selection ? "▶" : " "
            let state = entry.state == .normal ? "" : " (\(entry.state.rawValue))"
            let title = Log.showTitles ? "\"\(entry.title)\"" : "<title:\(entry.title.count)>"
            return "\(mark)\(entry.id) [\(entry.appName)] \(title)\(state)"
        }
        let more = s.entries.count > 8 ? " +\(s.entries.count - 8)" : ""
        let query = s.mode == .search ? " search:<\(s.query.count) chars>" : ""
        Log.info("switcher [\(event)]\(query) " + shown.joined(separator: " ") + more)
    }
}
