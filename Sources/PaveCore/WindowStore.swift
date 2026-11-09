/// The window manager's source of truth, as a pure value: every window known to
/// Pavé plus the most-recently-used order. Fed with per-app snapshots; reports
/// what changed so the UI and the logs can react.
public struct WindowStore: Sendable {
    public private(set) var windows: [WindowID: WindowSnapshot] = [:]
    /// Most recently focused first. Contains exactly the keys of `windows`.
    public private(set) var mru: [WindowID] = []

    public init() {}

    /// Windows in MRU order (what Alt+Tab will show).
    public var orderedWindows: [WindowSnapshot] { mru.compactMap { windows[$0] } }

    public func windows(of pid: PID) -> [WindowSnapshot] {
        windows.values.filter { $0.pid == pid }.sorted { $0.id < $1.id }
    }

    /// Replaces everything known about `snapshot.pid` with the snapshot.
    /// `isFrontmost`: whether that app is the active one, which makes its
    /// focused window the user's focused window.
    /// `keep`: asked for each known window the snapshot lacks; true keeps it as
    /// it was (AX only lists the current Space's windows: a window on another
    /// Space, or entering full screen, is not closed).
    @discardableResult
    public mutating func apply(
        _ snapshot: AppSnapshot, isFrontmost: Bool, keep: (WindowSnapshot) -> Bool = { _ in false }
    ) -> [WindowChange] {
        var changes: [WindowChange] = []
        let incoming = Dictionary(snapshot.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for old in windows(of: snapshot.pid) where incoming[old.id] == nil && !keep(old) {
            changes.append(.destroyed(old))
            remove(old.id)
        }

        for var new in snapshot.windows.sorted(by: { $0.id < $1.id }) {
            // macOS reports a minimized window as "AXDialog": keep the role it
            // had while visible (it vanished from the taskbar).
            if new.state == .minimized, let old = windows[new.id], old.subrole != new.subrole {
                new.subrole = old.subrole
            }
            guard let old = windows[new.id] else {
                windows[new.id] = new
                mru.append(new.id)
                changes.append(.created(new))
                continue
            }
            if old.frame != new.frame { changes.append(.frameChanged(new.id, from: old.frame, to: new.frame)) }
            if old.title != new.title { changes.append(.retitled(new.id, from: old.title, to: new.title)) }
            if old.state != new.state { changes.append(.stateChanged(new.id, from: old.state, to: new.state)) }
            windows[new.id] = new
        }

        if isFrontmost, let focused = snapshot.focusedWindow, windows[focused] != nil,
            mru.first != focused
        {
            mru.removeAll { $0 == focused }
            mru.insert(focused, at: 0)
            changes.append(.focused(focused))
        }
        return changes
    }

    /// Forgets an application (it quit). Reports its windows as destroyed.
    @discardableResult
    /// A frame Pavé just read back after moving `id`: fresher than the last
    /// snapshot, which lags behind by the coalescing delay (or more on slow apps).
    /// Without it, a command fired right after a move decided from the old frame.
    public mutating func updateFrame(_ id: WindowID, to frame: Rect) -> [WindowChange] {
        guard var window = windows[id], window.frame != frame else { return [] }
        let old = window.frame
        window.frame = frame
        windows[id] = window
        return [.frameChanged(id, from: old, to: frame)]
    }

    public mutating func removeApp(_ pid: PID) -> [WindowChange] {
        windows(of: pid).map { w in
            remove(w.id)
            return .destroyed(w)
        }
    }

    private mutating func remove(_ id: WindowID) {
        windows[id] = nil
        mru.removeAll { $0 == id }
    }
}
