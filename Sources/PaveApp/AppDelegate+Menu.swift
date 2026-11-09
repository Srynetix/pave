import AppKit
import PaveCore
import PaveIPC
import PaveMac
import ServiceManagement

/// The menu bar item and its menu, and the settings it toggles.
extension AppDelegate {
    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        let trusted = Permissions.isAccessibilityTrusted()
        statusLine.title = !trusted ? String(localized: "Pavé is waiting for the Accessibility permission")
            : started ? String(localized: "Pavé is running · tracked windows: \(registry.store.windows.count)")
            : String(localized: "Pavé is starting…")
        let state = workspaces.state
        // Workspaces off: no number in the menu bar, unless windows are still parked.
        let showWorkspace = started && (workspaces.isEnabled || state.hiddenCount > 0)
        workspaceItem.isHidden = !showWorkspace
        // One number per screen, in screen order; the focused screen's first when alone.
        let shown = Screens.all().compactMap { state.visible[$0.id] }
        let numbers = shown.count > 1 ? shown.map(String.init).joined(separator: " · ") : "\(state.active)"
        let title = shown.count > 1 ? String(localized: "Workspaces \(numbers)") : String(localized: "Workspace \(numbers)")
        workspaceItem.title = state.hiddenCount > 0
            ? String(localized: "\(title) · hidden windows: \(state.hiddenCount)") : title
        statusItem.button?.attributedTitle = showWorkspace ? menuBarNumbers(state) : NSAttributedString()
        let warning = currentWarning(trusted: trusted)
        warningItem.isHidden = warning == nil
        warningItem.title = warning.map { "⚠️ \($0)" } ?? ""
        refreshSettings()
        if windows.isSettingsVisible { updateSettingsModel() }
    }

    /// Next to the icon: the workspace shown on each screen, left to right as
    /// the screens are arranged, the active one in bold ("2 · **6**").
    func menuBarNumbers(_ state: Workspaces) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .bold)
        let regular = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let screens = Screens.all().sorted { $0.frame.x < $1.frame.x }
        let shown = screens.compactMap { state.visible[$0.id] }
        let numbers = shown.isEmpty ? [state.active] : shown
        let title = NSMutableAttributedString(string: " ")
        for (i, n) in numbers.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: " · ", attributes: [.font: regular, .foregroundColor: NSColor.secondaryLabelColor])) }
            let active = n == state.active && numbers.count > 1
            title.append(NSAttributedString(string: "\(n)", attributes: [.font: active ? bold : regular]))
        }
        return title
    }

    /// The one thing worth a look, if any (details in Settings > General).
    func currentWarning(trusted: Bool) -> String? {
        if !trusted { return String(localized: "Accessibility missing: Settings…") }
        if case .invalid = config.status { return String(localized: "Configuration not read: Settings…") }
        if NativeTiling.isEnabled { return String(localized: "macOS window tiling is on: Settings…") }
        if NativeTiling.stageManagerEnabled { return String(localized: "Stage Manager is on: Settings…") }
        let hung = registry.unresponsive.values.sorted()
        if !hung.isEmpty { return String(localized: "Apps not responding: \(hung.joined(separator: ", "))") }
        return nil
    }

    // MARK: - Settings (menu toggles)

    func refreshSettings() {
        let c = config.config
        workspacesToggle.isHidden = !started
        workspacesToggle.state = c.workspacesEnabled ? .on : .off
        // Tiling is per workspace: the toggle is for the one the user is on.
        let active = workspaces.state.active
        workspaceTilingToggle.isHidden = !started || !c.workspacesEnabled
        resetTaskbarItem.isHidden = !(taskbar?.isOn ?? false)
        switch updates.status {
        case .available(let release): updateItem.title = String(localized: "Install Pavé \(release.version)…")
        case .installing(let version): updateItem.title = String(localized: "Installing Pavé \(version)…")
        default: updateItem.title = String(localized: "Check for Updates…")
        }
        updateItem.isHidden = !UpdateService.isInstalledCopy
        workspaceTilingToggle.title = String(localized: "Tiling of workspace \(active)")
        workspaceTilingToggle.state = c.tilingWorkspaces.contains(active) ? .on : .off
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }

    var loginState: SettingsModel.Login {
        guard UpdateService.isInstalledCopy else { return .devCopy }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    func setLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        guard on != (service.status == .enabled) else { return }
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.info("login item: removed")
            } else {
                try service.register()
                Log.info("login item: registered (\(service.status == .requiresApproval ? "needs approval" : "enabled"))")
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            Log.info("login item: FAILED (\(error.localizedDescription))")
            showAlert(String(localized: "Could not launch at login"), error.localizedDescription)
        }
        refresh()
    }

    func bundleID(_ pid: PID) -> String? {
        if bundleIDsObserver == nil {
            bundleIDsObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
                MainActor.assumeIsolated { _ = self?.bundleIDs.removeValue(forKey: pid) }
            }
        }
        if let known = bundleIDs[pid] { return known }
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        bundleIDs[pid] = id
        return id
    }

    func toggleNativeTiling() {
        if !NativeTiling.set(enabled: !NativeTiling.isEnabled) {
            showAlert(String(localized: "macOS window tiling not changed"), String(localized: "macOS refused the write to com.apple.WindowManager."))
        }
        refresh()
    }

    @objc func toggleWorkspaceTiling() {
        _ = tilingCommand(["toggle"], windowID: nil)
    }

    @objc func toggleWorkspaces() {
        setConfig("workspaces", "enabled", to: config.config.workspacesEnabled ? "false" : "true")
    }

    /// Menu toggles go through the file: it stays the single source of truth.
    func setConfig(_ table: String, _ key: String, to value: String) {
        if let problem = config.set(table, key, to: value) {
            Log.info("config: \(table).\(key) not changed: \(problem)")
            showAlert(String(localized: "Setting not changed"), problem)
        }
        refresh()
    }

    func showAlert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    @objc func showLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    func reapplyRemap() {
        remap?.reapplyAll(reason: "menu")
    }

    /// Text of `pave config`: no window data, only settings.
    func configReport() -> String {
        let c = config.config
        var lines = ["file: \(config.url.path)"]
        switch config.status {
        case .defaults: lines.append("status: no file, built-in defaults")
        case .loaded(let warnings):
            lines.append("status: loaded" + (warnings.isEmpty ? "" : ", \(warnings.count) warning(s)"))
            lines += warnings.map { "  warning: \($0)" }
        case .invalid(let problem): lines.append("status: REJECTED (\(problem)), previous settings kept")
        }
        lines.append("workspaces.enabled = \(c.workspacesEnabled)")
        lines.append("switcher.scope = \(c.switcherScope.rawValue)")
        let active = c.activeBindings
        lines.append("hotkeys grabbed (\(active.count)):")
        lines += HotkeyAction.all.compactMap { action in
            guard let hotkey = c.bindings[action] ?? nil, active[hotkey] == action else { return nil }
            return "  \(action.configName) = \(hotkey.configName)"
        }
        return lines.joined(separator: "\n")
    }

    func openConfig() {
        NSWorkspace.shared.open(config.url)
    }
}
