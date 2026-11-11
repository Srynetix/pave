import AppKit
import PaveCore

/// Decides whether a window AX no longer lists is really gone. AX only sees
/// the current Space: with a
/// full-screen Space on, every other window of the screen vanished from the
/// registry and lost its workspace. A window whose ID the window server still
/// knows is kept:
/// - for good while SkyLight puts it on a Space no screen shows;
/// - else for a 2 s grace (a window entering or leaving full screen is
///   destroyed then re-created by AX ≈ 1 s later, same ID), then a new
///   snapshot decides. Only right after a Space change: a window the user
///   closes is still known during its closing animation, and must leave the
///   taskbar at once.
/// Windows hidden by their app stay on a shown Space: never kept for good.
@MainActor
final class SpaceTracker {
    static let grace: TimeInterval = 2
    private var missingSince: [WindowID: Date] = [:]
    /// Logged once per window while it stays away.
    private var reported: Set<WindowID> = []
    /// Asked to re-read an app once its grace is over.
    var requestSnapshot: (PID) -> Void = { _ in }
    private var lastSpaceChange = Date.distantPast
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lastSpaceChange = Date() } }
    }

    func shouldKeep(_ window: WindowSnapshot) -> Bool {
        guard Self.windowServerKnows(window.id, pid: window.pid) else { return forget(window.id) }
        if Self.isOnHiddenSpace(window.id) {
            if reported.insert(window.id).inserted {
                note(window, "on a Space no screen shows")
            }
            missingSince[window.id] = nil
            return true
        }
        guard Date().timeIntervalSince(lastSpaceChange) < Self.grace + 0.5 || missingSince[window.id] != nil else {
            return forget(window.id)
        }
        let since =
            missingSince[window.id]
            ?? {
                missingSince[window.id] = Date()
                let pid = window.pid
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace + 0.1) { [weak self] in
                    MainActor.assumeIsolated { self?.requestSnapshot(pid) }
                }
                return Date()
            }()
        if Date().timeIntervalSince(since) < Self.grace {
            if reported.insert(window.id).inserted { note(window, "grace, still known to the window server") }
            return true
        }
        return forget(window.id)
    }

    /// One log line per burst (a Space change hides several windows at once).
    private var pending: [String: [String]] = [:]

    private func note(_ window: WindowSnapshot, _ reason: String) {
        if pending.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (reason, windows) in self.pending.sorted(by: { $0.key < $1.key }) {
                        Log.info("kept \(windows.count) window(s) (W4), \(reason): \(windows.joined(separator: ", "))")
                    }
                    self.pending = [:]
                }
            }
        }
        pending[reason, default: []].append("\(window.id) [\(window.appName)]")
    }

    /// AX listed the window again.
    func seen(_ ids: [WindowID]) {
        for id in ids where missingSince[id] != nil || reported.contains(id) {
            missingSince[id] = nil
            reported.remove(id)
        }
    }

    private func forget(_ id: WindowID) -> Bool {
        missingSince[id] = nil
        reported.remove(id)
        return false
    }

    static func windowServerKnows(_ id: WindowID, pid: PID) -> Bool {
        guard
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id.rawValue))
                as? [[String: Any]],
            let info = list.first
        else { return false }
        return (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
    }

    /// Every Space holding the window is shown on no screen.
    static func isOnHiddenSpace(_ id: WindowID) -> Bool {
        let spaces = PrivateAPI.spaces(ofWindow: id.rawValue)
        guard !spaces.isEmpty else { return false }
        let current = PrivateAPI.currentSpaces()
        guard !current.isEmpty else { return false }
        return spaces.allSatisfy { !current.contains($0) }
    }
}
