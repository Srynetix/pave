import AppKit
import PaveCore

/// Main-actor owner of the WindowStore: connects to every regular app, merges
/// their snapshots and publishes the changes.
@MainActor
public final class WindowRegistry {
    public private(set) var store = WindowStore()
    /// Apps that currently time out on AX requests.
    public private(set) var unresponsive: [PID: String] = [:]
    /// Called after a batch that creates, destroys, focuses or changes the
    /// state of a window (not after moves and titles alone: see `publish`).
    public var onChange: (() -> Void)?
    /// Fired once, when every app running at start delivered its first snapshot
    /// (or after `readyTimeout`, if some app is hung).
    public var onReady: (() -> Void)?
    private var readyObservers: [() -> Void] = []
    /// Like `onReady`, for any number of observers (runs at once if already ready).
    public func whenReady(_ observer: @escaping () -> Void) {
        if isReady { observer() } else { readyObservers.append(observer) }
    }
    public private(set) var isReady = false
    static let readyTimeout: TimeInterval = 3

    private var changeObservers: [([WindowChange]) -> Void] = []
    private var pendingInitial: Set<PID> = []

    /// `observer` receives every non-empty batch of window changes.
    public func addChangeObserver(_ observer: @escaping ([WindowChange]) -> Void) {
        changeObservers.append(observer)
    }

    /// Snapshots slower than this are logged (H1 latency, H2 isolation).
    static let slowSnapshotThreshold: TimeInterval = 0.1
    /// Safety net for missed notifications. Each round wakes every app (a
    /// full AX snapshot each): notifications do the real work, this only
    /// catches what they missed.
    static let refreshInterval: TimeInterval = 30

    private var connections: [PID: AppConnection] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var refreshTimer: Timer?

    public init() {}

    public var appCount: Int { connections.count }

    /// Every tracked app, with whether it currently answers AX requests.
    public var trackedApps: [(pid: PID, name: String, responsive: Bool)] {
        connections.values.map { ($0.pid, $0.name, unresponsive[$0.pid] == nil) }
    }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        let handlers: [(Notification.Name, @MainActor @Sendable (WindowRegistry, PID) -> Void)] = [
            (NSWorkspace.didLaunchApplicationNotification, { r, pid in r.connect(pid) }),
            (NSWorkspace.didTerminateApplicationNotification, { r, pid in r.disconnect(pid) }),
            (NSWorkspace.didActivateApplicationNotification, { r, pid in r.activated(pid) }),
        ]
        for (name, handler) in handlers {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                        .processIdentifier
                    MainActor.assumeIsolated {
                        guard let self, let pid else { return }
                        handler(self, pid)
                    }
                })
        }

        // Locked session: macOS hides windows from AX clients. Snapshots taken then
        // are not the truth and must not turn into "window destroyed" (H4).
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            tokens.append(
                distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setSessionLocked(locked) }
                })
        }

        // Notifications only report transitions: read the current lock state too.
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            (session["CGSSessionScreenIsLocked"] as? Bool) == true
        {
            setSessionLocked(true)
        }

        for app in NSWorkspace.shared.runningApplications {
            connect(app.processIdentifier)
        }
        pendingInitial = Set(connections.keys)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in
            self?.becomeReady(reason: "timeout")
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.connections.values.forEach { $0.requestSnapshot() } }
        }
        // Apps only list the windows of the current Space through AX: in a
        // full-screen Space the others drop out of the registry, and used to
        // come back only with each app's next event or the periodic refresh
        // (5–9 s). Re-read every app once the new Space is shown.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                for delay in [0.25, 0.8] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        MainActor.assumeIsolated { self?.connections.values.forEach { $0.requestSnapshot() } }
                    }
                }
            }
        }
        Log.info("registry started, tracking \(connections.count) apps")
    }

    private var spaceObserver: NSObjectProtocol?

    /// True between screen lock and unlock: snapshots are ignored meanwhile.
    public private(set) var isSessionLocked = false

    private func setSessionLocked(_ locked: Bool) {
        guard locked != isSessionLocked else { return }
        isSessionLocked = locked
        Log.info(locked ? "session locked: window changes frozen" : "session unlocked: refreshing every app")
        if !locked { connections.values.forEach { $0.requestSnapshot() } }
        onChange?()
    }

    // MARK: - Acting on windows

    /// The window the user is working in: the frontmost app's most recently focused one.
    public var focusedWindow: WindowSnapshot? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return store.orderedWindows.first { $0.pid == pid }
    }

    public func setFrame(
        of window: WindowSnapshot, to target: Rect,
        completion: @escaping @MainActor (MoveResult) -> Void
    ) {
        guard let connection = connections[window.pid] else {
            return completion(
                MoveResult(
                    window: window.id.rawValue, target: target, actual: nil, constrained: false,
                    durationMs: 0, error: "app not tracked"))
        }
        let current = window.frame
        let plan: AppConnection.MovePlan
        if abs(current.width - target.width) < 1 && abs(current.height - target.height) < 1 {
            plan = .positionOnly
        } else {
            let screens = Screens.all()
            let from = LayoutEngine.screen(for: current, among: screens)?.id
            plan = from != nil && from == LayoutEngine.screen(for: target, among: screens)?.id ? .sameScreen : .full
        }
        connection.setFrame(window.id, target, plan: plan) { [weak self] result in
            Task { @MainActor [weak self] in
                if let actual = result.actual, let self { self.publish(self.store.updateFrame(window.id, to: actual)) }
                completion(result)
            }
        }
    }

    public func focus(_ window: WindowSnapshot, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let connection = connections[window.pid] else { return completion(false) }
        connection.focus(window.id) { ok in
            Task { @MainActor in completion(ok) }
        }
    }

    /// `pid`'s focused window, asked to the app now (FocusService checks).
    public func focusedWindowID(of pid: PID, completion: @escaping @MainActor (WindowID?) -> Void) {
        guard let connection = connections[pid] else { return completion(nil) }
        connection.focusedWindowID { id in Task { @MainActor in completion(id) } }
    }

    public func close(_ window: WindowSnapshot, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let connection = connections[window.pid] else { return completion(false) }
        connection.close(window.id) { error in
            Task { @MainActor in completion(error == .success) }
        }
    }

    public func minimize(_ window: WindowSnapshot, completion: @escaping @MainActor (Bool) -> Void) {
        guard let connection = connections[window.pid] else { return completion(false) }
        connection.minimize(window.id) { error in
            Task { @MainActor in completion(error == .success) }
        }
    }

    // MARK: - App lifecycle

    private func connect(_ pid: PID) {
        guard connections[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier,
            let app = NSRunningApplication(processIdentifier: pid),
            app.activationPolicy == .regular
        else { return }
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
        let connection = AppConnection(pid: pid, name: name) { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
        connections[pid] = connection
        connection.start()
    }

    private func disconnect(_ pid: PID) {
        guard let connection = connections.removeValue(forKey: pid) else { return }
        connection.stop()
        unresponsive[pid] = nil
        publish(store.removeApp(pid))
    }

    private func activated(_ pid: PID) {
        // Its focused window becomes the user's focus: refresh to learn which one.
        connections[pid]?.requestSnapshot()
    }

    // MARK: - Events from AppConnections

    private func receive(_ event: AppConnection.Event) {
        switch event {
        case .snapshot(let snapshot, let duration):
            // The app may have quit while the snapshot was in flight.
            guard let connection = connections[snapshot.pid], !isSessionLocked else { return }
            if duration > Self.slowSnapshotThreshold {
                Log.info("slow snapshot: \(connection.name) took \(Int(duration * 1000)) ms")
            }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid
            spaces.seen(snapshot.windows.map(\.id))
            publish(store.apply(snapshot, isFrontmost: frontmost, keep: { [spaces] in spaces.shouldKeep($0) }))
            if pendingInitial.remove(snapshot.pid) != nil, pendingInitial.isEmpty {
                becomeReady(reason: "all apps answered")
            }

        case .health(let pid, let responsive):
            guard let connection = connections[pid] else { return }
            unresponsive[pid] = responsive ? nil : connection.name
            Log.info("\(connection.name) (\(pid)) is \(responsive ? "responsive again" : "UNRESPONSIVE")")
            onChange?()
        }
    }

    private func becomeReady(reason: String) {
        guard !isReady else { return }
        isReady = true
        let missing = pendingInitial.compactMap { connections[$0]?.name }.sorted()
        Log.info(
            "registry ready (\(reason))"
                + (missing.isEmpty ? "" : ", still waiting for: \(missing.joined(separator: ", "))"))
        onReady?()
        readyObservers.forEach { $0() }
        readyObservers.removeAll()
    }

    /// Windows of other Spaces are kept.
    private lazy var spaces: SpaceTracker = {
        let tracker = SpaceTracker()
        tracker.requestSnapshot = { [weak self] pid in self?.connections[pid]?.requestSnapshot() }
        return tracker
    }()

    /// Set while the left button is down (window drags): frame changes are not logged one by one.
    public var quietFrameChanges = false

    private func publish(_ changes: [WindowChange]) {
        guard !changes.isEmpty else { return }
        for change in changes {
            // A drag moves the window dozens of times: the DragTracker logs one summary.
            if quietFrameChanges, case .frameChanged = change { continue }
            Log.info(change.describe(showTitles: Log.showTitles))
        }
        changeObservers.forEach { $0(changes) }
        // Moves, resizes and titles come by dozens a second during a drag or
        // an animation, and change nothing the menu shows: observers that care
        // get them through addChangeObserver.
        if changes.contains(where: { change in
            switch change {
            case .frameChanged, .retitled: false
            default: true
            }
        }) {
            onChange?()
        }
    }
}
