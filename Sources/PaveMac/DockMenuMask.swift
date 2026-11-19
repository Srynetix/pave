// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore
import ScreenCaptureKit

/// Hides the Dock's menu while Pavé reads it (ADR 0004): a still image of the
/// band it opens in, captured just before and shown above it, for the few tens
/// of milliseconds the menu is open. Needs the Screen Recording permission;
/// without it, or if the capture fails, nothing is covered.
///
/// The image shows what was on screen: it stays in memory, only as long as
/// the menu is open, never written nor logged.
@MainActor
final class DockMenuMask {
    /// Above the Dock's menu (`DockHelper`, at the pop-up menu level).
    static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    /// One frame, for the window server to show (or remove) the mask before the
    /// Dock opens (or after it closed) its menu.
    static let frameDelay: Duration = .milliseconds(17)
    /// The list of displays costs ~35 ms: reused while the screens stay the same.
    private var displays: [SCDisplay]?
    private var panel: NSPanel?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.displays = nil } }
    }

    /// Covers `band` (AX coordinates) with what it shows now. False when
    /// nothing could be covered.
    func cover(_ band: Rect) async -> Bool {
        guard CGPreflightScreenCaptureAccess(),
            let screen = NSScreen.screens.first(where: { Self.contains($0, band) }),
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let image = await capture(band, of: screen, display: number)
        else { return false }
        let frame = Screens.appKit(band)
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = Self.level
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resize
        panel.contentView = view
        panel.orderFrontRegardless()
        CATransaction.flush()
        self.panel = panel
        try? await Task.sleep(for: Self.frameDelay)
        return true
    }

    func uncover() async {
        guard let panel else { return }
        try? await Task.sleep(for: Self.frameDelay)
        panel.orderOut(nil)
        self.panel = nil
    }

    private func capture(_ band: Rect, of screen: NSScreen, display number: CGDirectDisplayID) async -> CGImage? {
        do {
            if displays == nil { displays = try await SCShareableContent.current.displays }
            guard let display = displays?.first(where: { $0.displayID == number }) else { return nil }
            let origin = Screens.axFrame(screen)
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(
                x: band.x - origin.x, y: band.y - origin.y, width: band.width, height: band.height)
            config.width = Int(band.width * screen.backingScaleFactor)
            config.height = Int(band.height * screen.backingScaleFactor)
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Log.info("taskbar: Dock menu mask not captured (\(error.localizedDescription))")
            return nil
        }
    }

    private static func contains(_ screen: NSScreen, _ band: Rect) -> Bool {
        let frame = Screens.axFrame(screen)
        return frame.contains(x: band.x + band.width / 2, y: band.y + band.height / 2)
    }
}
