import AppKit
import CoreGraphics
import PaveCore
import ScreenCaptureKit

/// Window previews for the switcher.
///
/// Capturing at opening time is too slow: one ScreenCaptureKit screenshot
/// takes 30–80 ms at best, up to ~900 ms (measured), so 20 windows
/// can never fit in 150 ms. Previews are therefore served **from a cache**,
/// kept fresh by event-driven captures, never by polling:
/// - when the user **leaves** a window (its content is what they saw last);
/// - once for every window at start-up, one at a time, in the background;
/// - when the switcher opens, for the first cards only (they update live).
///
/// Previews show window contents, which may be confidential: they stay **in
/// memory only**, are never written to disk, never logged. Logs carry counts,
/// durations and ages. Minimized windows cannot be captured: their last
/// preview is kept. Without the Screen Recording permission, nothing is
/// captured and the switcher shows app icons.
@MainActor
public final class ThumbnailService {
    /// Called on the main thread each time a preview arrives (switcher, taskbar).
    private var observers: [(WindowID, CGImage) -> Void] = []
    public func addUpdateObserver(_ observer: @escaping (WindowID, CGImage) -> Void) { observers.append(observer) }
    private func notify(_ id: WindowID, _ image: CGImage) { observers.forEach { $0(id, image) } }

    /// Output size of a capture, in pixels (preview area 176×108 pt, Retina ×2).
    nonisolated static let maxPixels = CGSize(width: 352, height: 216)
    /// In-memory cache bound (≈ 300 KB per preview).
    static let maxCached = 60
    /// Cards refreshed when the switcher opens (the rest comes from the cache).
    static let refreshedOnOpen = 8
    /// ScreenCaptureKit's window list costs 40–200 ms: reuse it for a while.
    static let listMaxAge: TimeInterval = 5

    private struct Preview {
        var image: CGImage
        var capturedAt: Date
    }

    private var cache: [WindowID: Preview] = [:]
    private var cacheOrder: [WindowID] = []
    /// Windows waiting for a background capture, in order; one capture at a time.
    private var queue: [WindowID] = []
    private var queueRunning = false
    private var list: (windows: [WindowID: SCWindow], at: Date)?
    private var openRefresh: Task<Void, Never>?
    private var permissionLogged = false

    public init() {}

    public func cached(_ id: WindowID) -> CGImage? { cache[id]?.image }

    public var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks once for Screen Recording (system prompt). The switcher works without it.
    public func requestPermissionIfNeeded() {
        guard !hasPermission else { return }
        Log.info("previews: Screen Recording not granted, asking (the switcher shows icons meanwhile)")
        CGRequestScreenCaptureAccess()
    }

    /// A window was closed: drop its preview.
    public func forget(_ id: WindowID) {
        cache[id] = nil
        cacheOrder.removeAll { $0 == id }
        queue.removeAll { $0 == id }
    }

    // MARK: - Background captures

    /// Queues windows for a background capture (start-up fill, focus left).
    public func captureLater(_ ids: [WindowID]) {
        guard hasPermission else { return }
        for id in ids where !queue.contains(id) { queue.append(id) }
        runQueue()
    }

    private func runQueue() {
        guard !queueRunning, !queue.isEmpty else { return }
        queueRunning = true
        let id = queue.removeFirst()
        Task { [weak self] in
            guard let self else { return }
            if let window = await self.scWindow(id), let image = try? await Self.shot(SendableWindow(window: window)) {
                self.store(id, image)
                self.notify(id, image)
            }
            self.queueRunning = false
            self.runQueue()
        }
    }

    // MARK: - Switcher opening

    /// The switcher opened on `entries`: logs how many previews the cache
    /// already had, then refreshes the first cards.
    public func switcherOpened(_ entries: [SwitcherSession.Entry]) {
        guard hasPermission else {
            if !permissionLogged { Log.info("previews: no Screen Recording permission, icons only") }
            permissionLogged = true
            return
        }
        let now = Date()
        let ages = entries.compactMap { cache[$0.id].map { now.timeIntervalSince($0.capturedAt) } }.sorted()
        let median = ages.isEmpty ? 0 : ages[ages.count / 2]
        Log.info(
            "previews (S3) at open: \(ages.count)/\(entries.count) from cache"
                + (ages.isEmpty ? "" : ", age median \(Int(median)) s, oldest \(Int(ages.last!)) s"))

        openRefresh?.cancel()
        let targets = entries.prefix(Self.refreshedOnOpen)
            .filter { $0.state == .normal || $0.state == .fullscreen }.map(\.id)
        openRefresh = Task { [weak self] in await self?.refreshNow(targets) }
    }

    private func refreshNow(_ ids: [WindowID]) async {
        let start = Date()
        var windows: [(WindowID, SendableWindow)] = []
        for id in ids {
            if let window = await scWindow(id) { windows.append((id, SendableWindow(window: window))) }
        }
        var done = 0
        var blank: [WindowID] = []
        await withTaskGroup(of: (WindowID, CGImage?).self) { group in
            for (id, window) in windows {
                group.addTask { (id, try? await Self.shot(window)) }
            }
            for await (id, image) in group {
                guard let image, !Task.isCancelled else { continue }
                done += 1
                if Self.isBlank(image) { blank.append(id) }
                store(id, image)
                notify(id, image)
            }
        }
        guard !Task.isCancelled else { return }
        let missing = Set(ids).subtracting(windows.map(\.0))
        Log.info(
            "previews: \(done)/\(ids.count) first cards refreshed in \(Int(Date().timeIntervalSince(start) * 1000)) ms"
                + (missing.isEmpty ? "" : ", not in ScreenCaptureKit: \(missing.sorted().map(\.description))")
                + (blank.isEmpty ? "" : ", BLANK: \(blank.map(\.description))"))
    }

    // MARK: - On demand (taskbar hover)

    public func capturedAt(_ id: WindowID) -> Date? { cache[id]?.capturedAt }

    /// Captures these windows now, in parallel; each result goes to the observers.
    public func refresh(_ ids: [WindowID]) {
        guard hasPermission, !ids.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            var windows: [(WindowID, SendableWindow)] = []
            for id in ids {
                if let window = await self.scWindow(id) { windows.append((id, SendableWindow(window: window))) }
            }
            await withTaskGroup(of: (WindowID, CGImage?).self) { group in
                for (id, window) in windows { group.addTask { (id, try? await Self.shot(window)) } }
                for await (id, image) in group {
                    guard let image else { continue }
                    self.store(id, image)
                    self.notify(id, image)
                }
            }
        }
    }

    // MARK: - ScreenCaptureKit

    /// The SCWindow for `id`, from a recent window list (refetched if too old
    /// or if the window is new).
    private func scWindow(_ id: WindowID) async -> SCWindow? {
        if let list, Date().timeIntervalSince(list.at) < Self.listMaxAge, let window = list.windows[id] {
            return window
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            return nil
        }
        let windows = Dictionary(content.windows.map { (WindowID($0.windowID), $0) }, uniquingKeysWith: { a, _ in a })
        list = (windows, Date())
        return windows[id]
    }

    /// One desktop-independent window capture: works wherever the window is,
    /// including parked off screen by the workspaces.
    private nonisolated static func shot(_ wrapped: SendableWindow) async throws -> CGImage {
        let window = wrapped.window
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let size = fitted(window.frame.size)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// True if the capture is a uniform image (nothing drawn). Only a verdict
    /// leaves this function: the image is reduced to 8×8 and compared, never
    /// stored or logged.
    nonisolated static func isBlank(_ image: CGImage) -> Bool {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        var spread = 0
        for channel in 0..<4 {
            let values = stride(from: channel, to: pixels.count, by: 4).map { Int(pixels[$0]) }
            spread = max(spread, values.max()! - values.min()!)
        }
        return spread < 4
    }

    /// Window aspect ratio kept, within `maxPixels`.
    nonisolated static func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return maxPixels }
        let scale = min(maxPixels.width / size.width, maxPixels.height / size.height)
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    /// SCWindow is an immutable description of a window, only read by the
    /// capture task: safe to hand over, though not marked Sendable by the SDK.
    struct SendableWindow: @unchecked Sendable { let window: SCWindow }

    private func store(_ id: WindowID, _ image: CGImage) {
        cache[id] = Preview(image: image, capturedAt: Date())
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > Self.maxCached { cache[cacheOrder.removeFirst()] = nil }
    }
}
