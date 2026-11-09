import AppKit
import PaveCore

/// Turns commands (from hotkeys or the CLI) into window actions.
@MainActor
public final class Commander {
    public struct Outcome: Sendable {
        public var window: WindowSnapshot?
        public var move: MoveResult?
        /// Human-readable result when nothing was moved (no-op, minimized, error).
        public var message: String?
    }

    private let registry: WindowRegistry
    private var engine = LayoutEngine()
    /// The screen and zones each window was last put in (Z3): a screen that
    /// comes back gets its windows back in their zones.
    private var zoneHomes: [WindowID: (screen: String, zones: [Int])] = [:]
    private var knownScreens: [String] = []
    private var screenObserver: NSObjectProtocol?
    private var screenWork: DispatchWorkItem?
    /// After the workspaces (3 s) have handled the change.
    static let screenReturnDelay: TimeInterval = 4
    /// The app rule of a window (config `[apps]`), set by the app delegate.
    public var rule: (WindowSnapshot) -> AppRule = { _ in AppRule() }
    /// The zone layout of a screen for the arrows, set by the app; nil: halves and quarters.
    public var screenZones: (Screen) -> ScreenZones? = { _ in nil }
    private let hud = ZonesHUD()

    public init(registry: WindowRegistry) {
        self.registry = registry
        knownScreens = Screens.all().map(\.id)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screensDidChange() } }
        registry.addChangeObserver { [weak self] changes in
            for change in changes {
                switch change {
                case .destroyed(let window):
                    self?.engine.forget(window.id)
                    self?.zoneHomes[window.id] = nil
                case .created(let window): self?.newWindow(window)
                default: break
                }
            }
        }
    }

    /// Applies `command` to `windowID`, or to the focused window when nil.
    public func perform(
        _ command: LayoutCommand, windowID: WindowID? = nil, source: String,
        completion: @escaping @MainActor (Outcome) -> Void = { _ in }
    ) {
        let received = Date()
        guard !registry.isSessionLocked else {
            Log.info("\(source) \(command.rawValue): session locked, ignored")
            return completion(Outcome(window: nil, move: nil, message: "session locked"))
        }
        let window = windowID.flatMap { registry.store.windows[$0] } ?? (windowID == nil ? registry.focusedWindow : nil)
        guard let window else {
            let message = windowID.map { "unknown window \($0)" } ?? "no focused window"
            Log.info("\(source) \(command.rawValue): \(message)")
            return completion(Outcome(window: nil, move: nil, message: message))
        }
        if let refusal = rule(window).refusal(for: window, via: .hotkey) {
            Log.info("\(source) \(command.rawValue) \(window.id) [\(window.appName)]: \(refusal)")
            return completion(Outcome(window: window, move: nil, message: refusal))
        }
        let screens = Screens.all()
        guard !screens.isEmpty else {
            return completion(Outcome(window: window, move: nil, message: "no screen"))
        }

        let tag = "\(source) \(command.rawValue) \(window.id) [\(window.appName)]"
        // Looked up once per screen for this key press.
        var layouts: [String: ScreenZones?] = [:]
        let zones: (Screen) -> ScreenZones? = { [screenZones] screen in
            if let known = layouts[screen.id] { return known }
            let found = screenZones(screen)
            layouts[screen.id] = found
            return found
        }
        switch engine.handle(command, window: window, screens: screens, zones: zones) {
        case .none(let reason):
            Log.info("\(tag): no-op (\(reason))")
            completion(Outcome(window: window, move: nil, message: reason))

        case .minimize:
            registry.minimize(window) { ok in
                Log.info("\(tag): minimize \(ok ? "ok" : "FAILED")")
                completion(Outcome(window: window, move: nil, message: ok ? "minimized" : "minimize failed"))
            }

        case .setFrame(let target):
            let zoned = Self.zones(of: target, among: screens, zones)
            if let zoned { hud.show(zoned.screen.visibleFrame, zoned.layout, lit: zoned.indices) }
            remember(window.id, zoned.map { ($0.screen.id, $0.indices) })
            registry.setFrame(of: window, to: target) { [weak self] result in
                if zoned != nil { self?.settle(window, result, screens: screens) }
                let total = Int(Date().timeIntervalSince(received) * 1000)
                let verdict = result.ok ? (result.constrained ? "ok (constrained, centered)" : "ok") : "MISS"
                let detail = result.error ?? "actual \(result.actual.map(\.description) ?? "?")"
                let place = zoned.map { " (zone \($0.indices.map { "\($0 + 1)" }.joined(separator: "+")) of \($0.layout.layout.name))" } ?? ""
                Log.info(
                    "\(tag): \(window.frame) → target \(target)\(place), \(detail), \(verdict), ax \(Int(result.durationMs)) ms, total \(total) ms"
                )
                completion(Outcome(window: window, move: result, message: nil))
            }
        }
    }

    /// The zones a target frame fills, on a screen that has a layout.
    private static func zones(
        of target: Rect, among screens: [Screen], _ zones: (Screen) -> ScreenZones?
    ) -> (screen: Screen, layout: ScreenZones, indices: [Int])? {
        guard let screen = LayoutEngine.screen(for: target, among: screens), let layout = zones(screen),
            let indices = layout.layout.zones(matching: target, in: screen.visibleFrame, gaps: layout.gaps)
        else { return nil }
        return (screen, layout, indices)
    }

    // MARK: - Drags

    /// A drag of `window` started: the frame to give it back, if it was placed.
    public func dragStarted(_ window: WindowSnapshot, cursorX: Double, cursorY: Double) -> Rect? {
        let restored = engine.dragStarted(window, cursorX: cursorX, cursorY: cursorY, screens: Screens.all())
        if restored != nil { zoneHomes[window.id] = nil }  // out of its zones
        return restored
    }

    /// The window was dropped in `zone`.
    public func drop(
        _ window: WindowSnapshot, in zone: SnapZones.Zone, completion: @escaping @MainActor (MoveResult?) -> Void
    ) {
        guard case .setFrame(let target) = engine.drop(window, at: zone.placement, on: zone.screen, screens: Screens.all())
        else { return completion(nil) }
        registry.setFrame(of: window, to: target) { result in completion(result) }
    }

    /// The window was dropped in zones, at `frame`.
    public func drop(
        _ window: WindowSnapshot, inZones frame: Rect, completion: @escaping @MainActor (MoveResult?) -> Void
    ) {
        let screens = Screens.all()
        guard case .setFrame(let target) = engine.drop(window, inZones: frame, screens: screens)
        else { return completion(nil) }
        rememberZones(of: window.id, at: target, among: screens)
        registry.setFrame(of: window, to: target) { [weak self] result in
            self?.settle(window, result, screens: screens)
            completion(result)
        }
    }

    // MARK: - Zone homes (Z3)

    private func remember(_ id: WindowID, _ home: (String, [Int])?) {
        zoneHomes[id] = home.map { (screen: $0.0, zones: $0.1) }
    }

    /// Records where a window placed at `target` sits, if in zones (with the
    /// layouts as the arrows see them, or the drag's).
    private func rememberZones(of id: WindowID, at target: Rect, among screens: [Screen]) {
        let found = Self.zones(of: target, among: screens) { [ruleZones] in ruleZones($0) }
        remember(id, found.map { ($0.screen.id, $0.indices) })
    }

    private func screensDidChange() {
        screenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.screensSettled() } }
        screenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.screenReturnDelay, execute: work)
    }

    /// A screen came back: the windows that were in its zones, now elsewhere
    /// (macOS moved them away when it went), go back to the same zone numbers.
    /// Parked windows (hidden workspace) are left to the workspaces.
    private func screensSettled() {
        let screens = Screens.all()
        let added = screens.filter { !knownScreens.contains($0.id) }
        knownScreens = screens.map(\.id)
        for screen in added {
            let returning = zoneHomes.filter { $0.value.screen == screen.id }
            guard !returning.isEmpty else { continue }
            guard let zones = ruleZones(screen) else {
                Log.info("zones: \(returning.count) window(s) had zones on a screen back without a layout, left where they are")
                continue
            }
            var moved = 0
            for (id, home) in returning {
                guard let window = registry.store.windows[id], !isParked(id),
                    LayoutEngine.screen(for: window.frame, among: screens) != screen
                else { continue }
                let kept = Array(Set(home.zones.map { min($0, zones.layout.zones.count - 1) })).sorted()
                let target = zones.layout.frame(of: kept, in: screen.visibleFrame, gaps: zones.gaps)
                guard case .setFrame(let frame)? = engine.returnToZones(window, target) else { continue }
                moved += 1
                registry.setFrame(of: window, to: frame) { [weak self] result in
                    self?.settle(window, result, screens: screens)
                    Log.info("zones \(id) [\(window.appName)]: back in zone \(kept.map { "\($0 + 1)" }.joined(separator: "+")) of \(zones.layout.name) (Z3), \(result.ok ? "ok" : "MISS")")
                }
            }
            Log.info("zones (Z3): screen back, \(moved) window(s) returned to their zones")
        }
    }

    /// The screen switched layouts: its windows in zones of `old` follow `new`.
    public func reflow(_ windows: [WindowSnapshot], on screen: Screen, from old: ScreenZones, to new: ScreenZones) {
        let screens = Screens.all()
        var moved = 0
        for window in windows {
            guard case .setFrame(let target)? = engine.reflow(window, from: old, to: new, on: screen) else { continue }
            moved += 1
            remember(window.id, new.layout.zones(matching: target, in: screen.visibleFrame, gaps: new.gaps).map { (screen.id, $0) })
            registry.setFrame(of: window, to: target) { [weak self] result in
                self?.settle(window, result, screens: screens)
                Log.info("zones \(window.id) [\(window.appName)]: \(old.layout.name) → \(new.layout.name), \(result.ok ? "ok" : "MISS")")
            }
        }
        if moved == 0 { Log.info("zones: \(old.layout.name) → \(new.layout.name), no window in zones") }
    }

    /// Parked by the workspaces (not shown): left alone. Set by the app.
    public var isParked: (WindowID) -> Bool = { _ in false }
    /// The layout of a screen for app rules (whatever `zones.keyboard` says).
    public var ruleZones: (Screen) -> ScreenZones? = { _ in nil }
    /// Apps place their new window themselves (size and position restored)
    /// right after it appears: the zone comes after them.
    static let newWindowDelay: TimeInterval = 0.35

    /// App rule `zone = N`: a new standard window goes into zone N of its
    /// screen, when that screen has a layout.
    private func newWindow(_ created: WindowSnapshot) {
        guard registry.isReady, let n = rule(created).zone, rule(created).refusal(for: created, via: .hotkey) == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.newWindowDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.registry.store.windows[created.id], !self.isParked(window.id) else { return }
                let screens = Screens.all()
                guard let screen = LayoutEngine.screen(for: window.frame, among: screens), let zones = self.ruleZones(screen) else {
                    return Log.info("\(window.id) [\(window.appName)]: zone \(n) (app rule) skipped, no layout on its screen")
                }
                self.place(window, inZone: n, of: zones, on: screen, source: "app rule", showZones: false)
            }
        }
    }

    /// Puts `window` into zone `n` (from 1) of `zones` on `screen`;
    /// `showZones`: the layout flashes with that zone lit, as for the arrows.
    public func place(
        _ window: WindowSnapshot, inZone n: Int, of zones: ScreenZones, on screen: Screen, source: String, showZones: Bool = true
    ) {
        guard case .setFrame(let target)? = engine.place(window, inZone: n - 1, of: zones, on: screen) else {
            let why = n > zones.layout.zones.count ? "\(zones.layout.name) has \(zones.layout.zones.count) zones" : "already there"
            return Log.info("\(window.id) [\(window.appName)]: zone \(n) (\(source)) skipped, \(why)")
        }
        let screens = Screens.all()
        remember(window.id, (screen.id, [n - 1]))
        if showZones { hud.show(screen.visibleFrame, zones, lit: [n - 1]) }
        registry.setFrame(of: window, to: target) { [weak self] result in
            self?.settle(window, result, screens: screens)
            Log.info("\(window.id) [\(window.appName)] → zone \(n) of \(zones.layout.name) (\(source)), \(result.ok ? "ok" : "MISS")")
        }
    }

    /// Is the window still in the zones it was put in (drop check, D2)?
    public func isInItsZones(_ window: WindowSnapshot) -> Bool { engine.zoneTarget(of: window) != nil }

    /// A window that refused its zone's size was centered there, maybe off
    /// the screen (a narrow edge zone): brought back on it, and remembered
    /// so it still counts as in its zone.
    private func settle(_ window: WindowSnapshot, _ result: MoveResult, screens: [Screen]) {
        guard result.constrained, let actual = result.actual,
            let area = LayoutEngine.screen(for: result.target, among: screens)?.visibleFrame
        else { return }
        let kept = LayoutEngine.keptOnScreen(actual, in: area)
        guard !kept.isClose(to: actual) else { return engine.settled(window.id, at: actual) }
        var moved = window
        moved.frame = actual
        registry.setFrame(of: moved, to: kept) { [weak self] second in
            let final = second.actual ?? kept
            self?.engine.settled(window.id, at: final)
            Log.info("zones \(window.id) [\(window.appName)]: refused \(Int(result.target.width))×\(Int(result.target.height)), kept on screen at \(final)")
        }
    }
}
