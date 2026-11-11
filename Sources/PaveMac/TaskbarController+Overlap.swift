// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// Windows under the bar: moved up above it (T2), unless their app rule allows it.
extension TaskbarController {
    // MARK: - Windows under the bar

    /// After a move, a resize or a new window: give the usable area back to a
    /// window that covers the bar (native zoom, apps maximizing themselves).
    func watchOverlaps(_ changes: [WindowChange]) {
        guard settings.enabled else { return }
        for change in changes {
            switch change {
            case .frameChanged(let id, _, _): scheduleOverlapCheck(id, receivedAt: Date())
            case .created(let window): scheduleOverlapCheck(window.id, receivedAt: Date())
            case .destroyed(let window):
                overlapChecks.removeValue(forKey: window.id)?.cancel()
                overlapFixes[window.id] = nil
            default: break
            }
        }
    }

    func scheduleOverlapCheck(_ id: WindowID, receivedAt: Date, delay: TimeInterval = 0.15) {
        overlapChecks[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkOverlap(id, receivedAt: receivedAt) }
        }
        overlapChecks[id] = work
        // Let a zoom animation end first.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func checkOverlap(_ id: WindowID, receivedAt: Date) {
        overlapChecks[id] = nil
        // A parked window (inactive workspace) sits in a corner on purpose.
        guard settings.enabled, let window = registry.store.windows[id], window.state == .normal,
            window.subrole == "AXStandardWindow", !isOutOfSight(id), !isTiled(id)
        else { return }
        let appRule = rule(window)
        guard !appRule.ignore, !appRule.taskbarOverlap else { return }
        // Never fight the user: wait for the mouse button to be released.
        if NSEvent.pressedMouseButtons != 0 {
            return scheduleOverlapCheck(id, receivedAt: receivedAt, delay: 0.3)
        }
        guard let screen = LayoutEngine.screen(for: window.frame, among: Screens.all()),
            let target = TaskbarOverlap.fix(window.frame, usable: screen.visibleFrame)
        else { return }
        // An app that keeps going back under the bar: give up for a while.
        let recent = (overlapFixes[id] ?? []).filter { Date().timeIntervalSince($0) < 10 }
        guard recent.count < 3 else {
            if recent.count == 3 {
                overlapFixes[id] = recent + [Date()]
                Log.info(
                    "taskbar overlap: \(id) [\(window.appName)] keeps covering the bar, left alone (rule taskbar-overlap = \"allow\" to silence)"
                )
            }
            return
        }
        overlapFixes[id] = recent + [Date()]
        registry.setFrame(of: window, to: target) { [weak self] result in
            guard let self else { return }
            let ms = Date().timeIntervalSince(receivedAt) * 1000
            if result.ok { self.overlapResults.ok += 1 } else { self.overlapResults.miss += 1 }
            self.overlapTimes.append(ms)
            let sorted = self.overlapTimes.sorted()
            Log.info(
                "taskbar overlap (T2): \(id) [\(window.appName)] \(window.frame) → \(target) \(result.ok ? "ok" : "MISS") "
                    + "\(Int(ms)) ms after the change · so far \(self.overlapResults.ok) ok, \(self.overlapResults.miss) miss, "
                    + "p50 \(Int(sorted[sorted.count / 2])) ms")
        }
    }
}
