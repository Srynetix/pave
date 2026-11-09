import AppKit
import PaveCore

/// Brings *one specific* window to the front.
///
/// Activating an app is not enough: macOS then shows the app's last active
/// window, not necessarily the one the user picked. So the window is raised
/// through AX, then the result is checked against reality: the frontmost app
/// (NSWorkspace) and the app's focused window (asked to the app, not taken
/// from the last snapshot). A miss is retried once. Every attempt is logged
/// (no title) so the success rate can be measured in daily use.
@MainActor
public final class FocusService {
    public enum Outcome: String, Sendable {
        case firstTry = "ok"
        case afterRetry = "ok after retry"
        case wrongApp = "MISS: another app is frontmost"
        case wrongWindow = "MISS: another window of the app is focused"
        case failed = "MISS: AX refused"
        /// The user asked for another window before this one was checked
        /// (quick ⌃Tab ⌃Tab): not a miss, not counted.
        case superseded = "superseded by a newer request"
    }

    /// Time given to macOS and the app to settle before checking.
    static let checkDelay: TimeInterval = 0.3
    /// A second check, later: catches an app that takes the focus back (seen
    /// with Prism, 184 ms after a switch).
    static let lateCheckDelay: TimeInterval = 1.5

    private let registry: WindowRegistry
    public private(set) var counts: [Outcome: Int] = [:]
    public private(set) var lateLosses = 0
    /// Bumped by every request: a later one makes the late check of an earlier
    /// one meaningless (the user moved on, nothing was stolen).
    private var generation = 0

    /// When Pavé last asked for each window (switcher, taskbar, CLI…): a focus
    /// change to it is then the user's will, not macOS's.
    public private(set) var requestedAt: [WindowID: Date] = [:]

    public init(registry: WindowRegistry) {
        self.registry = registry
    }

    /// Told before every focus request (the taskbar hides itself at once when
    /// a full-screen window is about to come up).
    private var willFocusObservers: [(WindowSnapshot) -> Void] = []
    public func addWillFocusObserver(_ observer: @escaping (WindowSnapshot) -> Void) { willFocusObservers.append(observer) }

    public func focus(
        _ window: WindowSnapshot, source: String, completion: @escaping @MainActor (Outcome) -> Void = { _ in }
    ) {
        let start = Date()
        requestedAt[window.id] = start
        willFocusObservers.forEach { $0(window) }
        generation += 1
        let request = generation
        attempt(window) { [weak self] first in
            guard let self else { return }
            if first == .firstTry { return self.done(window, first, source, start, completion) }
            if self.generation != request { return self.done(window, .superseded, source, start, completion) }
            Log.info("focus \(window.id) [\(window.appName)]: first try \(first.rawValue), retrying")
            // One retry: raising again usually wins once the app is active.
            self.attempt(window) { second in
                if second != .firstTry, self.generation != request { return self.done(window, .superseded, source, start, completion) }
                self.done(window, second == .firstTry ? .afterRetry : second, source, start, completion)
            }
        }
    }

    private func attempt(_ window: WindowSnapshot, completion: @escaping @MainActor (Outcome) -> Void) {
        // A hidden app (⌘H): AX alone does not bring it back, and asking for the
        // front while it unhides is ignored (the first try always missed).
        // Unhide, wait until *the window* is back on screen (the app says it is
        // visible before macOS shows its windows again, then puts its previous
        // key window in front: 2 first tries out of 5 in M1), then focus.
        if let app = NSRunningApplication(processIdentifier: window.pid), app.isHidden {
            app.unhide()
            let start = Date()
            return waitUntilOnScreen(window.id, deadline: start.addingTimeInterval(1)) { [weak self] in
                Log.info("focus \(window.id) [\(window.appName)]: unhidden, on screen after \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                // Let the unhide's own ordering finish first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    MainActor.assumeIsolated { self?.focusNow(window, completion: completion) }
                }
            }
        }
        focusNow(window, completion: completion)
    }

    private func waitUntilOnScreen(_ id: WindowID, deadline: Date, then: @escaping @MainActor () -> Void) {
        if Self.isOnScreen(id) || Date() > deadline { return then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            MainActor.assumeIsolated { self.waitUntilOnScreen(id, deadline: deadline, then: then) }
        }
    }

    static func isOnScreen(_ id: WindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id.rawValue)) as? [[String: Any]]
        return (list?.first?[kCGWindowIsOnscreen as String] as? Bool) == true
    }

    private func focusNow(_ window: WindowSnapshot, completion: @escaping @MainActor (Outcome) -> Void) {
        registry.focus(window) { [weak self] accepted in
            guard let self else { return }
            guard accepted else { return completion(.failed) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkDelay) {
                MainActor.assumeIsolated { self.check(window, completion: completion) }
            }
        }
    }

    private func check(_ window: WindowSnapshot, completion: @escaping @MainActor (Outcome) -> Void) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else {
            return completion(.wrongApp)
        }
        registry.focusedWindowID(of: window.pid) { focused in
            completion(focused == window.id ? .firstTry : .wrongWindow)
        }
    }

    private func done(
        _ window: WindowSnapshot, _ outcome: Outcome, _ source: String, _ start: Date,
        _ completion: @escaping @MainActor (Outcome) -> Void
    ) {
        if outcome != .superseded { counts[outcome, default: 0] += 1 }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        Log.info(
            "focus \(window.id) [\(window.appName)] from \(source): \(outcome.rawValue), \(ms) ms"
                + (outcome == .wrongApp ? " (frontmost: \(frontmost))" : "") + " · \(summary)")
        completion(outcome)
        guard outcome == .firstTry || outcome == .afterRetry else { return }
        let request = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lateCheckDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == request, NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid else { return }
                self.lateLosses += 1
                let thief = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                Log.info("focus \(window.id) [\(window.appName)]: LOST within \(Self.lateCheckDelay) s, \(thief) is frontmost")
            }
        }
    }

    /// The focus success rate so far, e.g. "14/15 first try, 1 after retry, 0 miss, 0 lost later".
    public var summary: String {
        let total = counts.values.reduce(0, +)
        let misses = total - counts[.firstTry, default: 0] - counts[.afterRetry, default: 0]
        return "S2 so far: \(counts[.firstTry, default: 0])/\(total) first try, "
            + "\(counts[.afterRetry, default: 0]) after retry, \(misses) miss, \(lateLosses) lost later"
    }
}
