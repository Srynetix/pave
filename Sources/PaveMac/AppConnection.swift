// SPDX-License-Identifier: MIT OR Apache-2.0
import ApplicationServices
import Foundation
import PaveCore

/// Everything Pavé does with one application's Accessibility API.
///
/// Threading: all stored AX state is confined to `thread` (an AppThread). Public
/// methods only enqueue work on it. Results go back through `sink`, which hops
/// to the main actor.
final class AppConnection: @unchecked Sendable {
    enum Event: Sendable {
        /// A full, fresh picture of the app's windows. `duration`: time spent in AX calls.
        case snapshot(AppSnapshot, duration: TimeInterval)
        /// The app stopped (or resumed) answering AX requests within the timeout.
        case health(PID, responsive: Bool)
    }

    /// Max time a single AX request may block before we call the app unresponsive.
    static let messagingTimeout: Float = 0.5
    /// How often an unresponsive app is probed for recovery.
    static let recoveryProbeInterval: TimeInterval = 2
    /// Delay before confirming a first failure.
    static let retryInterval: TimeInterval = 0.3
    /// Coalescing window for bursts of notifications (a drag fires dozens of kAXMoved).
    static let coalesceDelay: TimeInterval = 0.03

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification,
    ]
    /// Windows we manage. Panels, sheets, popovers, tooltips… are ignored.
    private static let managedSubroles: Set<String> = ["AXStandardWindow", "AXDialog"]

    let pid: PID
    let name: String
    private let sink: @Sendable (Event) -> Void
    private let thread = AppThread()

    // --- Confined to `thread` ---
    private var app: AXUIElement!
    private var observer: AXObserver?
    private var appNotificationsRegistered = false
    private var registrationAttempts = 0
    private var observed: [WindowID: AXUIElement] = [:]
    private var snapshotScheduled = false
    private var responsive = true
    /// `cannotComplete` also shows up briefly on healthy apps (Finder answered
    /// one after 90 ms): only consecutive failures mean "hung".
    private var consecutiveFailures = 0
    static let failuresBeforeUnresponsive = 2

    init(pid: PID, name: String, sink: @escaping @Sendable (Event) -> Void) {
        self.pid = pid
        self.name = name
        self.sink = sink
    }

    func start() {
        thread.name = "pave.ax.\(pid).\(name)"
        thread.startAndWait()
        thread.perform { self.setUp() }
    }

    func stop() {
        thread.perform {
            if let observer = self.observer {
                CFRunLoopRemoveSource(
                    CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            self.observer = nil
            self.observed.removeAll()
        }
        thread.stop()
    }

    /// Asks for a fresh snapshot (coalesced with any pending one).
    func requestSnapshot() {
        thread.perform { self.scheduleSnapshot() }
    }

    /// Moves/resizes a window and reports where it really ended (M0 / H1).
    /// How many AX calls a move needs. A resize is the costly call (the app
    /// lays itself out again: ≈ 20 ms for TextEdit), and the moves of one app
    /// are serial, so tiling 8 windows of one app adds them all up.
    enum MovePlan: Sendable {
        /// Size, position, size: the first resize may be clamped by the
        /// current screen edge, the second applies once on the new screen.
        case full
        /// Same screen: position, then one resize.
        case sameScreen
        /// Same size (parking, showing a workspace again): position only.
        case positionOnly
    }

    func setFrame(
        _ id: WindowID, _ target: Rect, plan: MovePlan = .full,
        completion: @escaping @Sendable (MoveResult) -> Void
    ) {
        thread.perform { completion(self.applyFrame(id, target, plan: plan)) }
    }

    /// Makes the app frontmost and raises `id` above its other windows.
    func focus(_ id: WindowID, completion: @escaping @Sendable (Bool) -> Void) {
        thread.perform {
            guard let window = self.observed[id] else { return completion(false) }
            // The switcher lists minimized windows too: picking one brings it back.
            if window.bool(kAXMinimizedAttribute) == true { window.set(kAXMinimizedAttribute, kCFBooleanFalse) }
            self.app.set(kAXFrontmostAttribute, kCFBooleanTrue)
            window.set(kAXMainAttribute, kCFBooleanTrue)
            completion(AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success)
        }
    }

    /// The app's own focused window, read live (not from the last snapshot).
    func focusedWindowID(completion: @escaping @Sendable (WindowID?) -> Void) {
        thread.perform { completion(self.app.element(kAXFocusedWindowAttribute)?.windowID) }
    }

    /// Presses the window's close button, like a click on the red light: the
    /// app may still ask to save, which is the expected behaviour.
    func close(_ id: WindowID, completion: @escaping @Sendable (AXError) -> Void) {
        thread.perform {
            guard let window = self.observed[id], let button = window.element(kAXCloseButtonAttribute) else {
                return completion(.invalidUIElement)
            }
            completion(AXUIElementPerformAction(button, kAXPressAction as CFString))
        }
    }

    func minimize(_ id: WindowID, completion: @escaping @Sendable (AXError) -> Void) {
        thread.perform {
            guard let window = self.observed[id] else { return completion(.invalidUIElement) }
            completion(window.set(kAXMinimizedAttribute, kCFBooleanTrue))
        }
    }

    // MARK: - On `thread`

    private func applyFrame(_ id: WindowID, _ target: Rect, plan: MovePlan) -> MoveResult {
        let start = Date()
        func result(_ actual: Rect?, constrained: Bool = false, error: String? = nil) -> MoveResult {
            MoveResult(
                window: id.rawValue, target: target, actual: actual, constrained: constrained,
                durationMs: Date().timeIntervalSince(start) * 1000, error: error)
        }
        guard let window = observed[id] else { return result(nil, error: "unknown window \(id)") }
        // A hung app would block this thread ~0.5 s per AX call (3.5 s per move
        // in the H2 campaign) and replay stale moves when it wakes up: refuse.
        guard responsive else { return result(nil, error: "app is unresponsive") }

        // Apps with AXEnhancedUserInterface on (set by assistive tools) animate and
        // fight frame changes: turn it off during the move (same trick as Rectangle).
        let (enhancedValue, enhancedError) = app.copy("AXEnhancedUserInterface")
        if enhancedError == .cannotComplete {
            noteFailure()
            return result(nil, error: "app did not answer within \(Self.messagingTimeout) s")
        }
        let enhanced = (enhancedValue as? NSNumber)?.boolValue == true
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) } }

        // See MovePlan. A size macOS clamped anyway is caught just below.
        if plan == .full { window.setSize(width: target.width, height: target.height) }
        let error = window.setPosition(x: target.x, y: target.y)
        if error == .cannotComplete {
            noteFailure()
            return result(nil, error: "app did not answer within \(Self.messagingTimeout) s")
        }
        if plan != .positionOnly { window.setSize(width: target.width, height: target.height) }

        guard var actual = window.frame else { return result(nil, error: "cannot read frame back") }
        // Moving to another screen (other scale): macOS may still clamp the size
        // to the old screen for a moment (1138 = built-in height − menu bar).
        // Try once more, a little later, before calling it constrained.
        if abs(actual.width - target.width) > 2 || abs(actual.height - target.height) > 2 {
            usleep(50_000)
            window.setPosition(x: target.x, y: target.y)
            window.setSize(width: target.width, height: target.height)
            actual = window.frame ?? actual
        }
        var constrained = false
        if abs(actual.width - target.width) > 2 || abs(actual.height - target.height) > 2 {
            constrained = true
            let centered = LayoutEngine.centered(width: actual.width, height: actual.height, in: target)
            window.setPosition(x: centered.x, y: centered.y)
            actual = window.frame ?? actual
        }
        return result(actual, constrained: constrained)
    }

    private func setUp() {
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<AppConnection>.fromOpaque(refcon).takeUnretainedValue().scheduleSnapshot()
        }
        if AXObserverCreate(pid, callback, &created) == .success, let created {
            observer = created
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        }
        registerAppNotifications()
        takeSnapshot()
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// A freshly launched app is often not ready for AX yet: retry for ~5 s.
    private func registerAppNotifications() {
        guard let observer, !appNotificationsRegistered else { return }
        registrationAttempts += 1
        let results = Self.appNotifications.map {
            AXObserverAddNotification(observer, app, $0 as CFString, refcon)
        }
        let ok = results.allSatisfy { $0 == .success || $0 == .notificationAlreadyRegistered }
        if ok {
            appNotificationsRegistered = true
        } else if registrationAttempts < 10 {
            thread.after(0.5) {
                self.registerAppNotifications()
                self.scheduleSnapshot()
            }
        } else {
            Log.info("\(name) (\(pid)): app notifications unavailable \(results.map(\.rawValue)), polling only")
        }
    }

    private func scheduleSnapshot() {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        thread.after(Self.coalesceDelay) {
            self.snapshotScheduled = false
            self.takeSnapshot()
        }
    }

    private func takeSnapshot() {
        let start = Date()
        let (windowsValue, error) = app.copy(kAXWindowsAttribute)

        if error == .cannotComplete {
            // Timed out or busy: the app may be hung (or stopped). Probe again,
            // quickly after a first failure, slowly once it is known to be hung.
            noteFailure()
            thread.after(responsive ? Self.retryInterval : Self.recoveryProbeInterval) { self.scheduleSnapshot() }
            return
        }
        consecutiveFailures = 0
        setResponsive(true)

        if error != .success && error != .noValue {
            logOnce("kAXWindows error \(error.rawValue)")
        }
        let elements = (windowsValue as? [AXUIElement]) ?? []

        // While the session is locked (screen saver, display asleep), macOS hands
        // AX clients a degraded tree: the window list holds the application
        // element itself. That is NOT "no window": reporting it would make Pavé
        // believe every window closed and forget where parked windows belong.
        if elements.contains(where: { $0.string(kAXRoleAttribute) == kAXApplicationRole }) {
            logOnce("degraded AX view (session locked?), snapshot skipped")
            thread.after(Self.recoveryProbeInterval) { self.scheduleSnapshot() }
            return
        }

        let hidden = app.bool(kAXHiddenAttribute) ?? false
        var windows: [WindowSnapshot] = []
        var seen: Set<WindowID> = []
        for element in elements {
            let id = element.windowID
            let role = element.string(kAXRoleAttribute)
            let subrole = element.string(kAXSubroleAttribute)
            let frame = element.frame
            guard let id, role == kAXWindowRole, let subrole, Self.managedSubroles.contains(subrole),
                let frame
            else {
                logOnce(
                    "skipped window id=\(id.map(\.description) ?? "nil") role=\(role ?? "nil") "
                        + "subrole=\(subrole ?? "nil") frame=\(frame.map(\.description) ?? "nil")")
                continue
            }

            let state: WindowState =
                if element.bool(kAXMinimizedAttribute) == true { .minimized } else if hidden {
                    .hidden
                } else if element.bool("AXFullScreen") == true { .fullscreen } else { .normal }

            windows.append(
                WindowSnapshot(
                    id: id, pid: pid, appName: name, title: element.string(kAXTitleAttribute) ?? "",
                    frame: frame, state: state, subrole: subrole,
                    minimizable: subrole == kAXStandardWindowSubrole && state == .normal
                        ? element.element(kAXMinimizeButtonAttribute)?.bool(kAXEnabledAttribute) == true : nil))
            seen.insert(id)
            observe(element, id: id)
        }
        observed = observed.filter { seen.contains($0.key) }

        let focused = app.element(kAXFocusedWindowAttribute)?.windowID
        let snapshot = AppSnapshot(pid: pid, windows: windows, focusedWindow: focused)
        sink(.snapshot(snapshot, duration: Date().timeIntervalSince(start)))
    }

    private func observe(_ window: AXUIElement, id: WindowID) {
        guard let observer, observed[id] == nil else { return }
        for notification in Self.windowNotifications {
            AXObserverAddNotification(observer, window, notification as CFString, refcon)
        }
        observed[id] = window
    }

    /// Diagnostics for windows Pavé ignores, logged once each (no titles).
    private var loggedOnce: Set<String> = []
    private func logOnce(_ message: String) {
        guard loggedOnce.insert(message).inserted else { return }
        Log.info("\(name) (\(pid)): \(message)")
    }

    private func noteFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failuresBeforeUnresponsive { setResponsive(false) }
    }

    private func setResponsive(_ value: Bool) {
        guard value != responsive else { return }
        responsive = value
        sink(.health(pid, responsive: value))
    }
}
