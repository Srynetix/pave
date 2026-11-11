import AppKit
import ApplicationServices

/// App badges (unread counts…) read from the Dock through Accessibility: the
/// Dock keeps running while hidden, and each of its items
/// exposes its app URL and its badge (`AXStatusLabel`). Polled every few
/// seconds while the taskbar is on, off the main thread, with a short AX
/// timeout. Only counts are logged.
@MainActor
final class DockBadges {
    /// Each read walks the Dock through AX (and wakes it): a badge may show
    /// a few seconds late.
    static let interval: TimeInterval = 5
    private var timer: Timer?
    private let queue = DispatchQueue(label: "pave.dock-badges")
    private(set) var badges: [String: String] = [:]  // bundle ID → label
    var onChange: () -> Void = {}

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        badges = [:]
    }

    private func poll() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return
        }
        let pid = dock.processIdentifier
        queue.async {
            let found = Self.read(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard found != self.badges else { return }
                    let before = self.badges.count
                    self.badges = found
                    if found.count != before { Log.info("taskbar: \(found.count) app badge(s) on the Dock") }
                    self.onChange()
                }
            }
        }
    }

    private nonisolated static func read(pid: pid_t) -> [String: String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
                return []
            }
            return value as? [AXUIElement] ?? []
        }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        var result: [String: String] = [:]
        for list in children(app) {
            for item in children(list) {
                guard let label = attribute(item, "AXStatusLabel") as? String, !label.isEmpty,
                    let url = attribute(item, kAXURLAttribute) as? URL,
                    let id = Bundle(url: url)?.bundleIdentifier
                else { continue }
                result[id] = label
            }
        }
        return result
    }
}
