/// What each taskbar shows. Pure: PaveMac feeds it the registry's windows and
/// draws the result.
///
/// Order, as Windows: pinned apps first (in pinned order), then the other
/// apps in the order their first window opened; the windows of one app are
/// side by side, in opening order (stable, not MRU). A pinned app
/// that has windows shows them in its slot instead of its pin.
public enum TaskbarGrouping: String, Sendable, CaseIterable {
    /// One entry per window (default).
    case never
    /// One entry per app.
    case always
    /// Per window, until the bar is full: then apps are combined, largest first.
    case whenFull = "when_full"
}

public struct TaskbarItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case window(WindowID)
        /// Several (or, with `always`, one or more) windows of one app.
        case group([WindowID])
        /// A pinned app with no window on this screen.
        case pinned
    }

    public var kind: Kind
    /// Bundle ID, or "pid:<n>" for an app without one.
    public var app: String
    /// nil for a pinned app that is not running.
    public var appName: String?
    public var pid: PID?
    /// Window title (window entries only): shown on screen, never logged.
    public var title: String?
    public var isActive: Bool
    /// Minimized or hidden (every window of a group).
    public var isDimmed: Bool
    public var isPinned: Bool
    /// The app's Dock badge ("3", "•"), on its first entry only.
    public var badge: String? = nil

    public var windowIDs: [WindowID] {
        switch kind {
        case .window(let id): [id]
        case .group(let ids): ids
        case .pinned: []
        }
    }
}

public struct TaskbarModel: Sendable {
    /// Width of one entry, in points (`when_full` and overflow).
    public struct Widths: Sendable {
        public var window: Double = 160
        /// Narrower than this, a title is unreadable: `when_full` combines apps first.
        public var readableWindow: Double = 110
        /// Last resort before the overflow (icon and a few letters).
        public var minWindow: Double = 56
        public var icon: Double = 44
        /// The line between pinned apps and the others (as `TaskbarPanel` draws it).
        public var separator: Double = 10
        public init() {}
    }

    /// Every window ever seen, in opening order (closed ones are dropped).
    public private(set) var openOrder: [WindowID] = []

    public init() {}

    /// Keeps the opening order up to date: new windows go to the end.
    public mutating func update(windows: [WindowSnapshot]) {
        let present = Set(windows.map(\.id))
        openOrder.removeAll { !present.contains($0) }
        let known = Set(openOrder)
        // New windows of one update: by ID, which grows with creation time.
        openOrder += windows.map(\.id).filter { !known.contains($0) }.sorted()
    }

    /// Entries of the bar on `screen`, and how many did not fit (`overflow`).
    /// - `hidden`: windows parked by the workspaces (not on the current one).
    /// - `bundleIDs`: per app; apps without one are keyed by PID.
    public func items(
        windows: [WindowSnapshot], on screen: Screen, screens: [Screen], active: WindowID?,
        bundleIDs: [PID: String], pinned: [String], grouping: TaskbarGrouping, width: Double,
        hidden: Set<WindowID> = [], widths: Widths = Widths()
    ) -> (items: [TaskbarItem], overflow: Int) {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Standard windows of this screen, in opening order.
        let shown = openOrder.compactMap { byID[$0] }.filter { window in
            // Minimized windows too: macOS reports them as "AXDialog".
            (window.subrole == "AXStandardWindow" || window.state == .minimized) && !hidden.contains(window.id)
                && LayoutEngine.screen(for: window.frame, among: screens) == screen
        }
        func key(_ w: WindowSnapshot) -> String { bundleIDs[w.pid] ?? "pid:\(w.pid)" }

        // Apps: pinned ones first, then by their first window.
        var apps: [String] = pinned
        for window in shown where !apps.contains(key(window)) { apps.append(key(window)) }
        let windowsOf = Dictionary(grouping: shown, by: key)

        func windowItem(_ w: WindowSnapshot) -> TaskbarItem {
            TaskbarItem(
                kind: .window(w.id), app: key(w), appName: w.appName, pid: w.pid, title: w.title,
                isActive: w.id == active, isDimmed: w.state == .minimized || w.state == .hidden,
                isPinned: pinned.contains(key(w)))
        }
        func groupItem(_ app: String, _ ws: [WindowSnapshot]) -> TaskbarItem {
            TaskbarItem(
                kind: .group(ws.map(\.id)), app: app, appName: ws.first?.appName, pid: ws.first?.pid, title: nil,
                isActive: ws.contains { $0.id == active },
                isDimmed: ws.allSatisfy { $0.state == .minimized || $0.state == .hidden },
                isPinned: pinned.contains(app))
        }
        func build(combined: Set<String>) -> [TaskbarItem] {
            apps.flatMap { app -> [TaskbarItem] in
                let ws = windowsOf[app] ?? []
                if ws.isEmpty {
                    return pinned.contains(app)
                        ? [TaskbarItem(kind: .pinned, app: app, appName: nil, pid: nil, title: nil,
                                       isActive: false, isDimmed: false, isPinned: true)]
                        : []
                }
                return combined.contains(app) ? [groupItem(app, ws)] : ws.map(windowItem)
            }
        }
        func entryWidth(_ item: TaskbarItem, windowWidth: Double) -> Double {
            if case .window = item.kind { return windowWidth }
            return widths.icon
        }
        /// With the separator, when pinned apps come first and others follow.
        func needed(_ items: [TaskbarItem], windowWidth: Double) -> Double {
            let pinnedCount = items.prefix { $0.isPinned }.count
            let separator = pinnedCount > 0 && pinnedCount < items.count ? widths.separator : 0
            return items.reduce(separator) { $0 + entryWidth($1, windowWidth: windowWidth) }
        }

        var items: [TaskbarItem]
        switch grouping {
        case .never:
            items = build(combined: [])
        case .always:
            items = build(combined: Set(apps))
        case .whenFull:
            // Combine as soon as titles would get unreadable, app with most
            // windows first; then the entries shrink, down to the minimum.
            var combined: Set<String> = []
            items = build(combined: combined)
            let candidates = apps.filter { (windowsOf[$0]?.count ?? 0) >= 2 }
                .sorted { (windowsOf[$0]?.count ?? 0) > (windowsOf[$1]?.count ?? 0) }
            for app in candidates where needed(items, windowWidth: widths.readableWindow) > width {
                combined.insert(app)
                items = build(combined: combined)
            }
        }
        // What still does not fit at the minimum width goes to the overflow.
        var fitting: [TaskbarItem] = []
        for item in items {
            guard needed(fitting + [item], windowWidth: widths.minWindow) <= width else { break }
            fitting.append(item)
        }
        return (fitting, items.count - fitting.count)
    }
}
