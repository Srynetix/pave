// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore
import PaveIPC
import PaveMac
import ServiceManagement

/// The Settings and About windows: the model they show, the actions they send.
extension AppDelegate {
    // MARK: - Settings and About windows

    @objc func openSettings() { windows.showSettings() }
    @objc func openAbout() { windows.showAbout() }

    /// Taskbar "Pin to Workspace": `[apps."…"] workspace = N` (nil: removed,
    /// and the rule too if nothing else is left in it).
    func pinToWorkspace(_ app: String, _ n: Int?) {
        let table = ConfigEdit.appTable(app)
        var problem = n.map { config.set(table, "workspace", to: "\($0)") } ?? config.remove(table, "workspace")
        if problem == nil, n == nil, config.config.appRules[app] == AppRule() { problem = config.removeTable(table) }
        if let problem {
            Log.info("config: workspace of \(app) not changed: \(problem)")
            showAlert(String(localized: "Setting not changed"), problem)
        }
        refresh()
    }

    /// Taskbar "This Window ▸ N" or "All Workspaces": a title rule from the
    /// window's title, then Settings on it, where the pattern is shortened to
    /// what stays the same ("*Work"): the full title rarely comes back.
    func pinWindowTitle(_ app: String, _ pattern: String, _ target: TitleTarget) {
        if let problem = config.setPrivateKey(ConfigEdit.appTable(app) + ".titles", pattern, to: target.toml) {
            Log.info("config: title rule of \(app) not changed: \(problem)")
            showAlert(String(localized: "Setting not changed"), problem)
            return
        }
        refresh()
        editAppRule(app)
    }

    /// Opens Settings on the app rules, with one for `app` (made if missing).
    func editAppRule(_ app: String) {
        if config.config.appRules[app] == nil {
            if let problem = config.set(ConfigEdit.appTable(app), "tile", to: "true") {
                showAlert(String(localized: "Setting not changed"), problem)
                return
            }
        }
        settingsModel.section = .apps
        settingsModel.focusedRule = app
        windows.showSettings()
    }

    func configureSettings() {
        let model = settingsModel
        windows.onOpen = { [weak self] in self?.updateSettingsModel() }
        model.setValue = { [weak self] table, key, value, logValue in
            guard let self else { return nil }
            defer { self.refresh() }
            return self.config.set(table, key, to: value, logValue: logValue)
        }
        model.removeValue = { [weak self] table, key in
            guard let self else { return nil }
            defer { self.refresh() }
            return self.config.remove(table, key)
        }
        model.setPrivateKey = { [weak self] table, key, value in
            guard let self else { return nil }
            defer { self.refresh() }
            return self.config.setPrivateKey(table, key, to: value)
        }
        model.removePrivateKey = { [weak self] table, key in
            guard let self else { return nil }
            defer { self.refresh() }
            return self.config.removePrivateKey(table, key)
        }
        model.removeTable = { [weak self] table in
            guard let self else { return nil }
            defer { self.refresh() }
            return self.config.removeTable(table)
        }
        model.setLogin = { [weak self] on in self?.setLogin(on) }
        model.toggleNativeTiling = { [weak self] in self?.toggleNativeTiling() }
        model.displayWorkspace = { [weak self] n, screen in
            self?.workspaces.display(n, onScreen: "\(screen)", source: "settings") { _ in self?.refresh() }
        }
        model.pauseHotkeys = { [weak self] paused in
            guard let self else { return }
            self.hotkeys?.update(bindings: paused ? [:] : self.config.config.activeBindings)
            Log.info("hotkeys \(paused ? "paused" : "resumed") (recording a shortcut in Settings)")
        }
        model.perform = { [weak self] action in
            guard let self else { return }
            switch action {
            case .openConfig: self.openConfig()
            case .revealConfig: NSWorkspace.shared.activateFileViewerSelecting([self.config.url])
            case .showLogs: self.showLogs()
            case .reapplyRemap: self.reapplyRemap()
            case .restoreAll: self.restoreAllFromMenu()
            case .accessibility: self.openAccessibilitySettings()
            case .screenRecording:
                self.thumbnails.requestPermissionIfNeeded()
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            case .onboarding: self.windows.showOnboarding()
            case .checkUpdates: self.updateFromMenu()
            case .stageManager:
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
            }
        }
        model.restart = { [weak self] in self?.relaunch() }
        model.requestRefresh = { [weak self] in self?.updateSettingsModel() }
        windows.onboardingDone = {
            UserDefaults.standard.set(true, forKey: "onboardingDone")
            Log.info("welcome guide done")
        }
        model.windowTitles = { [weak self] app in
            guard let self else { return [] }
            return self.registry.store.orderedWindows
                .filter { $0.subrole == "AXStandardWindow" && self.bundleID($0.pid) == app && !$0.title.isEmpty }
                .map {
                    SettingsModel.OpenWindow(title: $0.title, workspace: self.workspaces.state.workspace(of: $0.id))
                }
        }
        model.assignZoneLayout = { [weak self] index, name in
            guard let self else { return }
            let screens = Screens.all()
            guard screens.indices.contains(index) else { return }
            self.assignZones(name, on: screens[index], old: self.zones(on: screens[index]))
            self.refresh()
        }
        model.editZones = { [weak self] index, name in
            guard let self else { return }
            let screens = Screens.all()
            let screen =
                index.flatMap { screens.indices.contains($0) ? screens[$0] : nil }
                ?? Screens.underMouse(among: screens) ?? screens.first
            if let screen { self.openZoneEditor(on: screen, layoutName: name, assign: index != nil) }
        }
    }

    /// Quits and starts again (language change). A planned restart, like
    /// `just dev`: parked windows stay parked and the next run picks them up.
    func relaunch() {
        do {
            try Relaunch.afterExit(reason: "language change")
        } catch {
            showAlert(String(localized: "Could not restart Pavé"), error.localizedDescription)
        }
    }

    /// Fresh data for the Settings window (only while it is open).
    func updateSettingsModel() {
        let c = config.config
        let state = workspaces.state
        let screens = Screens.all()
        let names = Screens.names()
        let windowsByWorkspace = Dictionary(grouping: registry.store.windows.values) { state.workspace(of: $0.id) }
        let rows = Workspaces.range.map { n in
            SettingsModel.WorkspaceRow(
                id: n, name: n <= c.workspaceNames.count ? c.workspaceNames[n - 1] : "",
                icon: n <= c.workspaceIcons.count ? c.workspaceIcons[n - 1] : "",
                screen: state.home[n].flatMap { id in screens.firstIndex { $0.id == id } },
                visible: workspaces.isEnabled && state.isVisible(n),
                windows: windowsByWorkspace[n]?.count ?? 0)
        }
        var keyboards: [SettingsModel.KeyboardRow] =
            (remap?.keyboards.values.map { entry in
                let text: String =
                    switch entry.state {
                    case .pending: String(localized: "In progress…")
                    case .applied: String(localized: "Remapped")
                    case .stock: String(localized: "Left as is (None preset)")
                    case .skipped: String(localized: "Left alone")
                    case .failed(let why): String(localized: "Failed: \(why)")
                    }
                return SettingsModel.KeyboardRow(
                    id: entry.keyboard.configID, name: entry.keyboard.name, state: text,
                    remapped: { if case .applied = entry.state { true } else { false } }())
            } ?? []).sorted { $0.name < $1.name }
        for id in c.keyboardSkip.sorted() where !keyboards.contains(where: { $0.id == id }) {
            keyboards.append(
                .init(
                    id: id, name: id == "built-in" ? String(localized: "Built-in keyboard") : id,
                    state: String(localized: "Not connected"), remapped: false))
        }
        let apps = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .map {
                SettingsModel.RunningApp(bundleID: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var status = SettingsModel.Status()
        status.trusted = Permissions.isAccessibilityTrusted()
        status.screenRecording = thumbnails.hasPermission
        status.windows = registry.store.windows.count
        status.apps = registry.appCount
        status.hung = registry.unresponsive.values.sorted()
        status.screens = names.enumerated().map {
            $0.offset == 0 ? String(localized: "\($0.element) (main)") : $0.element
        }
        let remapped = keyboards.filter(\.remapped).count
        status.pcKeys = remap?.settings.enabled == true && c.keyboardPreset == .pc && remap?.karabinerRunning != true
        status.keyboard =
            !(remap?.settings.enabled ?? false)
            ? String(localized: "Remap off")
            : remap?.karabinerRunning == true
                ? String(localized: "Remap paused (Karabiner running)")
                : String(localized: "Remapped keyboards: \(remapped)")
        status.configPath = config.url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        switch config.status {
        case .defaults: status.configState = String(localized: "no file, defaults")
        case .loaded(let warnings):
            status.configState =
                warnings.isEmpty
                ? String(localized: "loaded without errors") : String(localized: "warnings: \(warnings.count)")
        case .invalid(let problem):
            status.configState = String(localized: "invalid")
            status.configError = "\(problem)"
        }
        status.nativeTiling = NativeTiling.isEnabled
        status.stageManager = NativeTiling.stageManagerEnabled
        status.login = loginState
        status.update = updateStatusText
        if case .available(let release) = updates.status { status.updateAvailable = release.version }
        status.updateBusy =
            [.checking].contains(updates.status) || { if case .installing = updates.status { true } else { false } }()
        status.canUpdate = UpdateService.isInstalledCopy
        let zoneSettings = c.zones
        settingsModel.updateZones(
            Screens.all().enumerated().compactMap { i, screen in
                guard let identity = Screens.identity(of: screen.id) else { return nil }
                let key = zoneSettings.screenKey(
                    screenID: screen.id, screenName: identity.name, isBuiltIn: identity.isBuiltIn)
                return .init(
                    id: i, name: identity.name,
                    key: key
                        ?? ZoneSettings.newScreenKey(
                            screenID: screen.id, screenName: identity.name, isBuiltIn: identity.isBuiltIn),
                    layout: key.flatMap { zoneSettings.screens[$0] } ?? ZoneSettings.none)
            })
        settingsModel.update(
            config: c, status: status, workspaces: rows,
            screens: names.enumerated().map { .init(id: $0.offset, name: $0.element) },
            keyboards: keyboards, runningApps: apps)
    }
}
