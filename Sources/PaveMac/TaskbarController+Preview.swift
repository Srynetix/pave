// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// Hover previews of an entry's windows.
extension TaskbarController {
    // MARK: - Hover previews

    func hover(_ item: TaskbarItem, view: NSView, inside: Bool) {
        guard let button = view as? TaskbarButton else { return }
        if inside {
            hideTimer?.invalidate()
            showTimer?.invalidate()
            guard !item.windowIDs.isEmpty else { return scheduleHide() }
            // Already showing one: follow the cursor at once, as Windows does.
            if preview.isVisible { return showPreview(item, anchor: button) }
            showTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverDelay, repeats: false) {
                [weak self, weak button] _ in
                MainActor.assumeIsolated {
                    guard let self, let button, let current = button.item else { return }
                    self.showPreview(current, anchor: button)
                }
            }
        } else {
            showTimer?.invalidate()
            scheduleHide()
        }
    }

    func showPreview(_ item: TaskbarItem, anchor: TaskbarButton) {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let windows = item.windowIDs.compactMap { registry.store.windows[$0] }
        guard !windows.isEmpty else { return hidePreview() }
        let switching = preview.windowIDs != windows.map(\.id)
        let icon =
            item.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon } ?? NSImage(
                named: NSImage.applicationIconName)!
        preview.show(windows, images: { [thumbnails] in thumbnails.cached($0) }, icon: icon, above: anchor)
        previewAnchor = anchor
        guard switching else { return }
        CATransaction.flush()
        // Preview latency: from the decision to show (hover delay over) to the preview on screen.
        let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000_000
        previewTimes.append(ms)
        let capturable = windows.filter { $0.state == .normal || $0.state == .fullscreen }
        previewHits.total += capturable.count
        previewHits.cached += capturable.filter { thumbnails.cached($0.id) != nil }.count
        if previewTimes.count % 10 == 0 {
            let sorted = previewTimes.sorted()
            Log.info(
                "taskbar preview (T3): n=\(sorted.count), shown p50 \(String(format: "%.1f", sorted[sorted.count / 2])) ms, "
                    + "p95 \(String(format: "%.1f", sorted[Int(Double(sorted.count) * 0.95)])) ms, "
                    + "from cache \(previewHits.cached)/\(previewHits.total)")
        }
        // Live while it is up: capture now, then every second (only these windows).
        thumbnails.refresh(capturable.map(\.id))
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: Self.liveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.preview.isVisible else { return }
                let ids = self.preview.windowIDs.filter {
                    let state = self.registry.store.windows[$0]?.state
                    return state == .normal || state == .fullscreen
                }
                self.thumbnails.refresh(ids)
            }
        }
    }

    func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.hideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePreview() }
        }
    }

    func hidePreview() {
        showTimer?.invalidate()
        hideTimer?.invalidate()
        liveTimer?.invalidate()
        liveTimer = nil
        preview.hide()
        previewAnchor = nil
    }
}
