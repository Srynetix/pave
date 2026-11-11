import AppKit
import PaveCore
import PaveIPC

/// Saved arrangements of windows (`Arrangement`): save the current one under
/// a name, restore it later. Restoring sends each open window to its
/// workspace and place, launches the apps that have no window, and places
/// their windows as they arrive (for `launchWindow` seconds).
///
/// Stored in `~/.local/state/pave/arrangements.json`: app bundle IDs, window
/// ranks, workspaces, frames and zones. Never a title.
@MainActor
public final class ArrangementController {
    private let registry: WindowRegistry
    private let workspaces: WorkspaceController
    public let url: URL
    public private(set) var arrangements: [Arrangement] = []

    /// Set by the app.
    public var bundleID: (PID) -> String? = { _ in nil }
    /// Windows Pavé may move (standard, not ignored by an app rule).
    public var isPlaceable: (WindowSnapshot) -> Bool = { _ in true }
    /// A screen's layout (zones placed by number when it still has one).
    public var screenZones: (Screen) -> ScreenZones? = { _ in nil }
    /// The zones a window fills, if any (for saving).
    public var zonesOf: (WindowSnapshot, Screen) -> [Int]? = { _, _ in nil }
    public var isTiledWorkspace: (Int) -> Bool = { _ in false }
    public var onChange: () -> Void = {}

    /// Places waiting for a window of a launched app, until `deadline`.
    private var waiting: [Arrangement.Place] = []
    private var deadline = Date.distantPast
    static let launchWindow: TimeInterval = 30

    public init(
        registry: WindowRegistry, workspaces: WorkspaceController,
        url: URL = StateFiles.url("arrangements.json")
    ) {
        self.registry = registry
        self.workspaces = workspaces
        self.url = url
        load()
        registry.addChangeObserver { [weak self] changes in
            for case .created(let window) in changes { self?.arrived(window) }
        }
    }

    public func arrangement(named name: String) -> Arrangement? { arrangements.first { $0.name == name } }

    // MARK: Save

    /// Saves the open windows under `name` (replacing one of that name).
    /// Returns a summary, or nil when there is nothing to save.
    @discardableResult
    public func save(_ name: String) -> String? {
        let screens = Screens.all()
        let state = workspaces.state
        let windows = candidates()
        let ranks = Arrangement.indices(of: windows.map(\.candidate))
        let places: [Arrangement.Place] = windows.compactMap { window, candidate in
            // A parked window: where it will come back.
            let frame = state.savedFrames[window.id] ?? window.frame
            guard let screen = LayoutEngine.screen(for: frame, among: screens), let rank = ranks[window.id] else {
                return nil
            }
            var shown = window
            shown.frame = frame
            return Arrangement.Place(
                app: candidate.app, index: rank, workspace: workspaces.isEnabled ? state.workspace(of: window.id) : nil,
                screen: screen.id, frame: frame, zones: zonesOf(shown, screen))
        }
        guard !places.isEmpty else { return nil }
        arrangements.removeAll { $0.name == name }
        arrangements.append(Arrangement(name: name, places: places))
        arrangements.sort { $0.name.lowercased() < $1.name.lowercased() }
        write()
        let apps = Set(places.map(\.app)).count
        Log.info("arrangement saved: \(places.count) window(s) of \(apps) app(s)")
        return "\(places.count) window(s) of \(apps) app(s)"
    }

    public func delete(_ name: String) -> Bool {
        guard arrangements.contains(where: { $0.name == name }) else { return false }
        arrangements.removeAll { $0.name == name }
        write()
        Log.info("arrangement deleted")
        return true
    }

    // MARK: Restore

    /// Restores `name`: a summary, or nil if there is no such arrangement.
    public func restore(_ name: String) -> String? {
        guard let arrangement = arrangement(named: name) else { return nil }
        let windows = candidates()
        let match = arrangement.match(windows.map(\.candidate))
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.window.id, $0.window) })
        for (id, place) in match.placed {
            if let window = byID[id] { put(window, at: place) }
        }
        waiting = match.waiting
        deadline = Date().addingTimeInterval(Self.launchWindow)
        for app in match.appsToLaunch { launch(app) }
        Log.info(
            "arrangement restored: \(match.placed.count) window(s) placed, \(match.waiting.count) waiting, "
                + "\(match.appsToLaunch.count) app(s) launched")
        var summary = "\(match.placed.count) window(s) placed"
        if !match.appsToLaunch.isEmpty { summary += ", \(match.appsToLaunch.count) app(s) launched" }
        return summary
    }

    /// A window of a launched app (or a late one): the next place of its app.
    private func arrived(_ window: WindowSnapshot) {
        guard !waiting.isEmpty, Date() < deadline, registry.isReady, isPlaceable(window),
            let app = bundleID(window.pid), let index = waiting.firstIndex(where: { $0.app == app })
        else { return }
        let place = waiting.remove(at: index)
        // The app places its window itself first (restored size): come after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.registry.store.windows[window.id] else { return }
                self.put(current, at: place)
            }
        }
    }

    /// Sends a window to its workspace, then its place. A place on a hidden
    /// workspace is where the window comes back when it shows.
    private func put(_ window: WindowSnapshot, at place: Arrangement.Place) {
        let screens = Screens.all()
        let target = frame(for: place, among: screens)
        let state = workspaces.state
        guard workspaces.isEnabled, let n = place.workspace else {
            return setFrame(window, target)
        }
        let tiled = isTiledWorkspace(n)
        if state.workspace(of: window.id) == n {
            if state.isHidden(window.id) {
                if !tiled { workspaces.setReturnFrame(window.id, target) }
            } else if !tiled {
                setFrame(window, target)
            }
        } else if state.isVisible(n) || tiled {
            // Shown somewhere: there first, then the place (the tiling lays it out itself).
            workspaces.move(window.id, to: n, source: "arrangement") { [weak self] _ in
                guard !tiled, let self, let moved = self.registry.store.windows[window.id] else { return }
                self.setFrame(moved, target)
            }
        } else {
            // Hidden: placed first, so it is parked from (and comes back to) its place.
            setFrame(window, target) { [weak self] in
                self?.workspaces.move(window.id, to: n, source: "arrangement")
            }
        }
    }

    private func setFrame(_ window: WindowSnapshot, _ target: Rect, then: (@MainActor () -> Void)? = nil) {
        guard !window.frame.isClose(to: target) else {
            then?()
            return
        }
        registry.setFrame(of: window, to: target) { result in
            if !result.ok { Log.info("arrangement: \(window.id) [\(window.appName)] MISS at \(target)") }
            then?()
        }
    }

    /// The zones when its screen still has a layout with them, else the saved
    /// frame; a screen gone: the same place on the main screen.
    private func frame(for place: Arrangement.Place, among screens: [Screen]) -> Rect {
        if let screen = screens.first(where: { $0.id == place.screen }) {
            if let zones = place.zones, let layout = screenZones(screen), let last = zones.max(),
                last < layout.layout.zones.count
            {
                return layout.layout.frame(of: zones, in: screen.visibleFrame, gaps: layout.gaps)
            }
            return place.frame
        }
        guard let main = screens.first else { return place.frame }
        let source = LayoutEngine.screen(for: place.frame, among: screens)?.visibleFrame ?? place.frame
        return LayoutEngine.carry(place.frame, from: source, to: main.visibleFrame)
    }

    private func launch(_ app: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else {
            return Log.info("arrangement: \(app) is not installed, its places stay empty")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            Log.info("arrangement: launch \(app) " + (error.map { "FAILED (\($0.localizedDescription))" } ?? "ok"))
        }
    }

    // MARK: -

    private func candidates() -> [(window: WindowSnapshot, candidate: Arrangement.Candidate)] {
        registry.store.orderedWindows.compactMap { window in
            guard window.state != .minimized, isPlaceable(window), let app = bundleID(window.pid) else { return nil }
            return (window, Arrangement.Candidate(id: window.id, app: app))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            arrangements = try JSONDecoder().decode([Arrangement].self, from: data)
        } catch {
            Log.info("arrangements file unreadable (\(error)), ignored")
        }
    }

    private func write() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try StateFiles.write(encoder.encode(arrangements), to: url)
        } catch {
            Log.info("arrangements not saved: \(error.localizedDescription)")
        }
        onChange()
    }
}
