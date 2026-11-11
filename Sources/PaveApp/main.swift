import AppKit
import PaveCore
import PaveIPC
import PaveMac
import ServiceManagement

/// Menu-bar agent: tracks every window (WindowRegistry), places them
/// (Commander), runs the virtual workspaces, tiling and taskbar, and answers
/// the `pave` CLI (IPCServer). Logs go to build/pave.log with `just run`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var statusItem: NSStatusItem!
    // The menu: status, the two toggles used often, then the windows (the
    // other settings are in the Settings window).
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let workspaceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let warningItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: "")
    var remap: KeyboardRemapService?
    let updates = UpdateService()
    let updateItem = NSMenuItem(
        title: String(localized: "Check for Updates…"), action: #selector(updateFromMenu), keyEquivalent: "")
    let resetTaskbarItem = NSMenuItem(
        title: String(localized: "Reset Taskbar"), action: #selector(resetTaskbarFromMenu), keyEquivalent: "")
    let workspacesToggle = NSMenuItem(
        title: String(localized: "Virtual workspaces"), action: #selector(toggleWorkspaces), keyEquivalent: "")
    let workspaceTilingToggle = NSMenuItem(title: "", action: #selector(toggleWorkspaceTiling), keyEquivalent: "")
    var taskbar: TaskbarController?
    let dock = DockController()
    let settingsModel = SettingsModel()
    lazy var windows = PaveWindows(model: settingsModel)
    let config = ConfigStore()
    let registry = WindowRegistry()
    lazy var commander = Commander(registry: registry)
    lazy var workspaces = WorkspaceController(registry: registry)
    var ipc: IPCServer?
    var hotkeys: HotkeyService?
    lazy var focus = FocusService(registry: registry)
    lazy var tiling = TilingController(registry: registry, workspaces: workspaces, focus: focus)
    lazy var drags = DragSnapController(registry: registry, commander: commander)
    let thumbnails = ThumbnailService()
    let zonePicker = ZonePicker()
    /// The screen the open picker is about.
    var pickerScreen: Screen?
    /// The window the zone picker may put into a zone (focused at opening).
    var pickerWindow: WindowID?
    let zoneEditor = ZoneEditor()
    lazy var arrangements = ArrangementController(registry: registry, workspaces: workspaces)
    let arrangementPicker = ArrangementPicker()
    let arrangementsMenu = NSMenu()
    var editorScreen: Screen?
    /// Saving uses the layout on `editorScreen` (false from Settings › Layouts).
    var editorAssigns = true
    lazy var switcher = SwitcherController(
        registry: registry, workspaces: workspaces, focus: focus, thumbnails: thumbnails,
        config: { [unowned self] in self.config.config },
        endTapSession: { [weak self] id in self?.hotkeys?.endSession(id) })
    var layoutObserver: NSObjectProtocol?
    var signalSources: [DispatchSourceSignal] = []
    var started = false
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    /// Max time given to bring parked windows back before quitting anyway.
    static let quitRestoreTimeout: TimeInterval = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Pavé at a time: two would grab the same hotkeys twice, run two
        // switchers and fight over the socket and the parked windows.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
            let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
                $0 != me && !$0.isTerminated
            })
        {
            Log.info("another Pavé is already running (pid \(other.processIdentifier)): quitting")
            exit(0)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image()

        let menu = NSMenu()
        menu.delegate = self
        for item in [statusLine, workspaceItem, warningItem] { menu.addItem(item) }
        menu.addItem(.separator())
        for item in [workspaceTilingToggle, workspacesToggle] { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: String(localized: "Edit Zone Layouts…"), action: #selector(editZonesFromMenu), keyEquivalent: "")
        )
        let arrangementsItem = NSMenuItem(
            title: String(localized: "Window Arrangements"), action: nil, keyEquivalent: "")
        arrangementsItem.submenu = arrangementsMenu
        menu.addItem(arrangementsItem)
        menu.addItem(
            NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(
            NSMenuItem(title: String(localized: "About Pavé"), action: #selector(openAbout), keyEquivalent: ""))
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: String(localized: "Show Logs"), action: #selector(showLogs), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(resetTaskbarItem)
        menu.addItem(
            NSMenuItem(
                title: String(localized: "Bring Back All Windows"), action: #selector(restoreAllFromMenu),
                keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(
                title: String(localized: "Quit Pavé"), action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
        statusItem.menu = menu

        installSignalHandlers()
        let trusted = Permissions.isAccessibilityTrusted(prompt: true)
        Log.info("launched build \(build) from \(Bundle.main.bundlePath), accessibility trusted: \(trusted)")
        let native = NativeTiling.enabledSettings()
        if !native.isEmpty {
            Log.info("native tiling is ON (\(native.joined(separator: ", "))): it will snap along with Pavé")
        }
        if NativeTiling.stageManagerEnabled {
            Log.info("Stage Manager is ON: it moves windows on its own, against workspaces and tiling")
        }

        registry.onChange = { [weak self] in self?.refresh() }
        configureSettings()
        startWhenTrusted()
        // First launch: the welcome guide (permissions, keyboard, what to turn on).
        if !UserDefaults.standard.bool(forKey: "onboardingDone") { windows.showOnboarding() }
    }

    // MARK: - Quitting without losing windows

    /// SIGTERM (`pkill`, `just run`) and SIGINT go through the normal quit path,
    /// which brings parked windows back first.
    func installSignalHandlers() {
        // Belt and braces with SO_NOSIGPIPE: a client hanging up early must never
        // kill Pavé (it would leave parked windows off screen until next launch).
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Log.info("signal \(sig) received, quitting")
                NSApplication.shared.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Set once parked windows have been dealt with: the next terminate goes through.
    var readyToQuit = false

    /// Parked windows are brought back *before* quitting. This deliberately does
    /// not use `.terminateLater`: AppKit then spins a modal loop inside the
    /// current main-queue block (e.g. the SIGTERM handler), and the AX
    /// completions and the timeout, queued on the main queue too, could never
    /// run: Pavé hung forever. Instead: cancel, restore, terminate again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard started, !readyToQuit, workspaces.state.hiddenCount > 0 else { return .terminateNow }
        // A restart (`just run`, `just install`): the next run picks the
        // parked windows up where they are (WorkspaceController.recover).
        if RestartMarker.isSet, workspaces.prepareRestart() {
            return .terminateNow
        }
        readyToQuit = true
        var done = false
        let quit = {
            guard !done else { return }
            done = true
            NSApplication.shared.terminate(nil)
        }
        workspaces.restoreAll(source: "quit") { count in
            Log.info("quit: \(count) parked window(s) brought back")
            quit()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitRestoreTimeout) {
            MainActor.assumeIsolated {
                if !done { Log.info("quit: restore timed out, state kept on disk for next launch") }
                quit()
            }
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        dock.quitting()
        ipc?.stop()
    }

    // MARK: - Hotkeys and CLI

    /// A config reload changed something (the hotkey service, if not started
    /// yet, picks the bindings up when it starts).
    func apply(_ new: PaveConfig) {
        workspaces.setEnabled(new.workspacesEnabled)
        tiling.update(settings: Self.tilingSettings(new))
        Self.applyDragSettings(new, to: drags)
        hotkeys?.update(bindings: new.activeBindings)
        remap?.update(settings: Self.remapSettings(new))
        taskbar?.update(settings: Self.taskbarSettings(new))
        taskbar?.workspacesChanged()  // names in the workspace numbers
        hotkeys?.setOptionTap(enabled: new.taskbarEnabled && new.taskbarOptionOpensLauncher)
        applyUpdates(new)
        refresh()
    }

    var updatesScheduled = false
    static func applyDragSettings(_ c: PaveConfig, to drags: DragSnapController) {
        drags.magnetDistance = Double(c.windowMagnet)
        drags.resizeNeighbours = c.resizeNeighbours
        drags.magnetFill = c.magnetFill
    }

    static func tilingSettings(_ c: PaveConfig) -> TilingController.Settings {
        .init(workspaces: c.tilingWorkspaces, gaps: Double(c.tilingGaps))
    }

    static func taskbarSettings(_ c: PaveConfig) -> TaskbarController.Settings {
        .init(
            enabled: c.taskbarEnabled, grouping: c.taskbarGrouping, pinned: c.taskbarPinned, hideDock: c.taskbarHideDock
        )
    }

    func startTaskbar() {
        guard taskbar == nil else { return }
        let workspaces = self.workspaces
        taskbar = TaskbarController(
            registry: registry, focus: focus, thumbnails: thumbnails, dock: dock,
            settings: Self.taskbarSettings(config.config),
            bundleID: { [unowned self] pid in self.bundleID(pid) },
            rule: { [unowned self] window in self.commander.rule(window) },
            isOutOfSight: { id in workspaces.isEnabled ? workspaces.state.isOutOfSight(id) : false },
            setPinned: { [unowned self] list in
                let value = "[" + list.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
                self.setConfig("taskbar", "pinned", to: value)
            })
        taskbar?.workspaceIndicator = { [unowned self] screen in
            guard workspaces.isEnabled, let primary = Screens.all().first else { return [] }
            return WorkspaceIndicator.items(
                for: screen.id, primaryID: primary.id, state: workspaces.state,
                windows: Array(registry.store.windows.values), names: config.config.workspaceNames,
                icons: config.config.workspaceIcons)
        }
        taskbar?.switchWorkspace = { [unowned self] n in
            workspaces.switchTo(n, source: "taskbar") { [weak self] _ in self?.refresh() }
        }
        taskbar?.workspaceOf = { id in workspaces.isEnabled ? workspaces.state.workspace(of: id) : nil }
        taskbar?.workspaceNames = { [unowned self] in config.config.workspaceNames }
        taskbar?.moveToWorkspace = { [unowned self] ids, n in
            for id in ids {
                workspaces.move(id, to: n, source: "taskbar") { [weak self] message in
                    Log.info("taskbar: move \(id) to workspace \(n): \(message)")
                    self?.refresh()
                }
            }
        }
        workspaces.addChangeObserver { [weak self] in self?.taskbar?.workspacesChanged() }
        taskbar?.isTiled = { [unowned self] id in self.tiling.isTiled(id) }
    }

    static func remapSettings(_ c: PaveConfig) -> KeyboardRemapService.Settings {
        .init(enabled: c.keyboardRemap, preset: c.keyboardPreset, skip: c.keyboardSkip)
    }

    /// Needs no permission, but reads the config: started right after it.
    func startRemap() {
        let service = KeyboardRemapService(settings: Self.remapSettings(config.config))
        service.onChange = { [weak self] in self?.refresh() }
        service.start()
        remap = service
    }

    func startHotkeys() {
        let service = HotkeyService(bindings: config.config.activeBindings) { [weak self] action, hotkey in
            Task { @MainActor in self?.perform(action, source: "key \(hotkey)") }
        }
        let switcher = self.switcher
        service.onSwitcher = { key in switcher.handle(key) }
        let drags = self.drags
        service.onMouse = { event in drags.handle(event) }
        service.onOptionTap = { [weak self] in self?.taskbar?.toggleLauncher() }
        service.onPicker = { [weak self] key in self?.pickerKey(key) }
        zonePicker.onClose = { [weak service] id in service?.endSession(id) }
        arrangementPicker.onClose = { [weak service] id in service?.endSession(id) }
        arrangementPicker.onRestore = { [weak self] name in self?.restoreArrangement(name) }
        arrangementPicker.onSave = { [weak self] in self?.saveArrangementFromUI() }
        zonePicker.onChoose = { [weak self] name, zone in self?.pickZones(name, zone: zone) }
        zonePicker.onEdit = { [weak self] name in
            guard let self, let screen = self.pickerScreen else { return }
            self.pickerScreen = nil
            self.openZoneEditor(on: screen, layoutName: name == ZoneSettings.none ? nil : name)
        }
        zoneEditor.onSave = { [weak self] layout, gaps in
            // nil is success: not to be confused with a gone self.
            guard let self else { return "Pavé is quitting" }
            return self.saveZoneLayout(layout, gaps: gaps)
        }
        layoutObserver = KeyboardLayout.observeChanges { [weak service] in
            service?.update(layout: KeyboardLayout.current())
            Log.info("keyboard layout changed: switcher keys updated")
        }
        if service.start() { hotkeys = service }
        service.setOptionTap(enabled: config.config.taskbarEnabled && config.config.taskbarOptionOpensLauncher)
        // After start(): the tap thread must be running to receive it.
        service.update(layout: KeyboardLayout.current())
    }

    func perform(_ action: HotkeyAction, source: String) {
        switch action {
        case .layout(let command):
            if tiling.handles(command) {
                tiling.perform(command, source: source)
            } else {
                commander.perform(command, source: source)
            }
        case .focus(let direction): tiling.focus(direction, source: source)
        case .resize(let direction): tiling.resize(direction, source: source)
        case .toggleFloating: tiling.toggleFloating(source: source)
        case .zonePicker, .arrangementPicker: break  // a tap session (pickerKey)
        case .workspace(let n): workspaces.switchTo(n, source: source) { [weak self] _ in self?.refresh() }
        case .moveToWorkspace(let n): workspaces.move(nil, to: n, source: source) { [weak self] _ in self?.refresh() }
        case .switcher, .switcherSameApp: break  // sessions are run by the tap + SwitcherController
        }
    }

    /// Bundle ID of a running app (cached: asked for every placement).
    /// Forgotten when the app quits: macOS may give its pid to another one.
    var bundleIDs: [PID: String] = [:]
    var bundleIDsObserver: NSObjectProtocol?
    @objc func resetTaskbarFromMenu() { taskbar?.reset() }

    @objc func restoreAllFromMenu() {
        workspaces.restoreAll(source: "menu") { [weak self] _ in self?.refresh() }
    }

    func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
