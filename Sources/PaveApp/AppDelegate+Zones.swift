// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore
import PaveIPC
import PaveMac
import ServiceManagement

/// Zones: the layout of each screen, the picker (⌃⇧Z), `pave zones`, the editor.
extension AppDelegate {
    /// The zone layout of a screen, for the workspace it shows. None on a
    /// tiled workspace: tiling keeps the hand (Z-c).
    /// `keyboard`: for the arrows (needs `zones.keyboard`); `quiet`: no log line.
    func zones(on screen: Screen, keyboard: Bool = false, quiet: Bool = false) -> ScreenZones? {
        let settings = config.config.zones
        guard settings.enabled, !keyboard || settings.keyboard, let identity = Screens.identity(of: screen.id) else {
            return nil
        }
        let workspace = workspaces.isEnabled ? workspaces.state.visible[screen.id] : nil
        // Drags log why (once per screen per press); key presses stay quiet.
        let log: (String) -> Void = {
            if !keyboard, !quiet {
                Log.info("zones: \($0) on \(identity.name), workspace \(workspace.map(String.init) ?? "-")")
            }
        }
        if let workspace, tiling.isTiledWorkspace(workspace) {
            log("none (tiled workspace)")
            return nil
        }
        guard
            let layout = settings.layout(
                screenID: screen.id, screenName: identity.name, isBuiltIn: identity.isBuiltIn, workspace: workspace)
        else {
            log("none (no layout for this screen)")
            return nil
        }
        log(layout.name)
        return .init(layout: layout, gaps: Double(settings.gaps), needsControl: settings.show == .ctrl)
    }

    // MARK: - Zone picker (⌃⇧Z)

    func pickerKey(_ key: HotkeyService.PickerKey) {
        guard case .open(let id, let action) = key else {
            return arrangementPicker.isOpen ? arrangementPicker.handle(key) : zonePicker.handle(key)
        }
        if action == .arrangementPicker { return openArrangementPicker(id) }
        let settings = config.config.zones
        let screens = Screens.all()
        let screen =
            registry.focusedWindow.flatMap { LayoutEngine.screen(for: $0.frame, among: screens) }
            ?? Screens.underMouse(among: screens) ?? screens.first
        guard settings.enabled, let screen, let identity = Screens.identity(of: screen.id) else {
            hotkeys?.endSession(id)
            return Log.info("zones: picker not opened (zones off or no screen)")
        }
        let workspace = workspaces.isEnabled ? workspaces.state.visible[screen.id] : nil
        if let workspace, tiling.isTiledWorkspace(workspace) {
            hotkeys?.endSession(id)
            return Log.info("zones: picker not opened on \(identity.name), workspace \(workspace) is tiled")
        }
        let current = settings.layout(
            screenID: screen.id, screenName: identity.name, isBuiltIn: identity.isBuiltIn, workspace: workspace)
        pickerScreen = screen
        // The focused window, if it can go into a zone of this screen.
        pickerWindow = registry.focusedWindow.flatMap { window in
            window.state == .normal && !workspaces.state.isHidden(window.id) && !tiling.isTiled(window.id)
                && LayoutEngine.screen(for: window.frame, among: screens) == screen
                && commander.rule(window).refusal(for: window, via: .hotkey) == nil ? window.id : nil
        }
        Log.info(
            "zones: picker opened on \(identity.name), current \(current?.name ?? ZoneSettings.none)\(pickerWindow == nil ? ", no window to place" : "")"
        )
        zonePicker.open(
            id: id, area: screen.visibleFrame, screenName: identity.name,
            choices: settings.choices.map { .init(name: $0, layout: settings.layout(named: $0)) },
            current: current?.name ?? ZoneSettings.none, canPlace: pickerWindow != nil)
    }

    /// A layout was picked for `pickerScreen`. Alone, it becomes the screen's
    /// layout (`assignZones`). With `zone`, only the window focused at opening
    /// goes into that zone of it: the screen keeps its layout, the other
    /// windows stay where they are.
    func pickZones(_ name: String, zone: Int? = nil) {
        guard let screen = pickerScreen else { return }
        pickerScreen = nil
        let windowID = pickerWindow
        pickerWindow = nil
        guard let zone else { return assignZones(name, on: screen, old: zones(on: screen)) }
        let settings = config.config.zones
        guard let id = windowID, let window = registry.store.windows[id], let layout = settings.layout(named: name)
        else {
            return Log.info("zones: picker zone \(zone) skipped, the window or the layout is gone")
        }
        let current = zones(on: screen, quiet: true)
        let target = ScreenZones(
            layout: layout, gaps: Double(settings.gaps), needsControl: current?.needsControl ?? (settings.show == .ctrl)
        )
        commander.place(window, inZone: zone, of: target, screenZones: current, on: screen, source: "zone picker")
    }

    /// `name` becomes the layout of `screen`: written to the config (the
    /// visible workspace's override if it has one, else the screen's), and
    /// the windows that were in zones of `old` follow it (`zones.follow`).
    func assignZones(_ name: String, on screen: Screen, old: ScreenZones?) {
        guard let identity = Screens.identity(of: screen.id) else { return }
        let settings = config.config.zones
        let workspace = workspaces.isEnabled ? workspaces.state.visible[screen.id] : nil
        if let workspace, settings.workspaces[workspace] != nil {
            setConfig("zones.workspaces", "\(workspace)", to: ConfigEdit.string(name))
        } else {
            let key =
                settings.screenKey(screenID: screen.id, screenName: identity.name, isBuiltIn: identity.isBuiltIn)
                ?? ZoneSettings.newScreenKey(
                    screenID: screen.id, screenName: identity.name, isBuiltIn: identity.isBuiltIn)
            setConfig("zones.screens", key, to: ConfigEdit.string(name))
        }
        Log.info("zones: \(name) for \(identity.name)")
        // Read after the writes: the layout may have just been saved by the editor.
        guard config.config.zones.follow else { return commander.rehome(windowsInZones(on: screen), on: screen) }
        guard let old, let layout = config.config.zones.layout(named: name) else { return }
        let new = ScreenZones(layout: layout, gaps: Double(config.config.zones.gaps), needsControl: old.needsControl)
        commander.reflow(windowsInZones(on: screen), on: screen, from: old, to: new)
    }

    /// Windows a layout change may move on `screen`: shown, floating, placeable.
    func windowsInZones(on screen: Screen) -> [WindowSnapshot] {
        let screens = Screens.all()
        return registry.store.orderedWindows.filter { window in
            window.state == .normal && !workspaces.state.isHidden(window.id) && !tiling.isTiled(window.id)
                && LayoutEngine.screen(for: window.frame, among: screens) == screen
                && commander.rule(window).refusal(for: window, via: .hotkey) == nil
        }
    }

    // MARK: - Zones CLI

    /// `pave zones …`: a report, or a change through the same paths as the UI.
    func zonesCommand(_ args: [String]) -> (Bool, String) {
        let settings = config.config.zones
        let screens = Screens.all()
        func screen(_ selector: String) -> Screen? { Screens.index(matching: selector).map { screens[$0] } }
        let command: ZonesCommand
        switch ZonesCommand.parse(args) {
        case .failure(let usage): return (false, usage.description)
        case .success(let parsed): command = parsed
        }
        switch command {
        case .report:
            var lines = [
                "zones: \(settings.enabled ? "on" : "off"), gaps \(settings.gaps), show \(settings.show.rawValue), keyboard \(settings.keyboard ? "on" : "off"), follow \(settings.follow ? "on" : "off")"
            ]
            lines.append("screens:")
            for (i, s) in screens.enumerated() {
                guard let identity = Screens.identity(of: s.id) else { continue }
                let key = settings.screenKey(screenID: s.id, screenName: identity.name, isBuiltIn: identity.isBuiltIn)
                let layout = key.flatMap { settings.screens[$0] } ?? ZoneSettings.none
                let now = zones(on: s, keyboard: true)?.layout.name ?? ZoneSettings.none
                lines.append(
                    "  \(i) \(identity.name): \(layout)" + (key.map { " (key \"\($0)\")" } ?? "")
                        + (now != layout ? ", now \(now)" : ""))
            }
            if !settings.workspaces.isEmpty {
                lines.append(
                    "workspaces: "
                        + settings.workspaces.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(
                            separator: ", "))
            }
            let layouts = settings.names.map { name in
                settings.layouts[name].map { "\(name) (\($0.zones.count) zones)" } ?? name
            }
            lines.append("layouts: " + layouts.joined(separator: ", "))
            return (true, lines.joined(separator: "\n"))
        case .enable(let on):
            setConfig("zones", "enabled", to: on ? "true" : "false")
            return (true, "zones \(on ? "on" : "off")")
        case .set(let selector, let layout):
            guard let target = screen(selector) else { return (false, "no screen matches \"\(selector)\"") }
            guard settings.choices.contains(layout) else {
                return (false, "unknown layout \"\(layout)\"; layouts: " + settings.choices.joined(separator: ", "))
            }
            assignZones(layout, on: target, old: zones(on: target))
            return (true, "\(Screens.identity(of: target.id)?.name ?? target.id) → \(layout)")
        case .edit(let selector, let layout):
            // A screen named but not found is an error, never the one under the mouse.
            let target = selector.map { screen($0) } ?? (Screens.underMouse(among: screens) ?? screens.first)
            guard let target else { return (false, "no screen matches \"\(selector ?? "")\"") }
            if let layout, settings.layout(named: layout) == nil { return (false, "unknown layout \"\(layout)\"") }
            openZoneEditor(on: target, layoutName: layout)
            return (true, "editor opened on \(Screens.identity(of: target.id)?.name ?? target.id)")
        }
    }

    // MARK: - Zone editor

    @objc func editZonesFromMenu() {
        let screens = Screens.all()
        guard let screen = Screens.underMouse(among: screens) ?? screens.first else { return }
        openZoneEditor(on: screen, layoutName: nil)
    }

    /// Opens the editor on `screen`, from `layoutName`, else the layout the
    /// screen uses, else a new one (`new`: always a new one). Every layout can
    /// then be opened from its Layout menu.
    func openZoneEditor(on screen: Screen, layoutName: String?, new: Bool = false, assign: Bool = true) {
        guard let identity = Screens.identity(of: screen.id) else { return }
        let settings = config.config.zones
        let workspace = workspaces.isEnabled ? workspaces.state.visible[screen.id] : nil
        let start =
            new
            ? nil
            : layoutName
                ?? settings.layout(
                    screenID: screen.id, screenName: identity.name, isBuiltIn: identity.isBuiltIn, workspace: workspace
                )?.name
        let entries = settings.names.compactMap { name in
            settings.layout(named: name).map {
                ZoneEditorSession.Entry(layout: $0, isMine: settings.layouts[name] != nil)
            }
        }
        zoneEditor.open(
            .init(screen: screen, screenName: identity.name, entries: entries, start: start, gaps: settings.gaps))
        // After opening: replacing an open editor closes it, which forgets its screen.
        editorScreen = screen
        editorAssigns = assign
    }

    /// The editor saved a layout: written as `[layouts."<name>"]`, with the
    /// gaps. The one it opened on (or made from it) is then used on the edited
    /// screen (zones turned on if they were off).
    func saveZoneLayout(_ saved: ZoneEditor.Saved) -> String? {
        let layout = saved.layout
        let gaps = saved.gaps
        guard let screen = editorScreen else { return "the screen went away" }
        // The editor checked its own list; the file may have gained the name since.
        if saved.isNew, config.config.zones.layouts[layout.name] != nil {
            return String(localized: "A layout is already named \(layout.name): choose another name")
        }
        let assigns = editorAssigns && saved.isOrigin
        let old = zones(on: screen)
        // Screens already using this layout: their windows follow the new version.
        let users = Screens.all().compactMap { s in
            zones(on: s, quiet: true).flatMap { $0.layout.name == layout.name ? (s, $0) : nil }
        }
        if let problem = config.replaceTable("layouts.\"\(layout.name)\"", "zones", to: layout.tomlZones) {
            return problem
        }
        if gaps != config.config.zones.gaps, let problem = config.set("zones", "gaps", to: "\(gaps)") { return problem }
        if !config.config.zones.enabled, let problem = config.set("zones", "enabled", to: "true") { return problem }
        Log.info("zones: layout \(layout.name) saved, \(layout.zones.count) zones, gaps \(gaps)")
        if assigns { assignZones(layout.name, on: screen, old: old) }
        let zones = config.config.zones
        for (s, before) in users where !(assigns && s == screen) {
            guard zones.follow else {
                commander.rehome(windowsInZones(on: s), on: s)
                continue
            }
            guard let written = zones.layout(named: layout.name) else { continue }
            commander.reflow(
                windowsInZones(on: s), on: s, from: before,
                to: ScreenZones(layout: written, gaps: Double(zones.gaps), needsControl: before.needsControl))
        }
        return nil
    }

    /// The registry needs Accessibility: wait for the user to grant it.
    func startWhenTrusted() {
        if Permissions.isAccessibilityTrusted() {
            started = true
            _ = commander  // installs its registry hooks
            commander.rule = { [unowned self] window in self.config.config.rule(for: self.bundleID(window.pid)) }
            workspaces.workspaceRule = { [unowned self] window in
                self.commander.rule(window).workspaceChoice(title: window.title)
            }
            workspaces.paveRequestedFocus = { [unowned self] id in self.focus.requestedAt[id] }
            workspaces.refocus = { [unowned self] window in self.focus.focus(window, source: "W3 refocus") }
            tiling.rule = { [unowned self] window in self.commander.rule(window) }
            tiling.update(settings: Self.tilingSettings(config.config))
            drags.isTiled = { [unowned self] id in self.tiling.isTiled(id) }
            drags.isShown = { [unowned self] id in !self.workspaces.isEnabled || !self.workspaces.state.isOutOfSight(id)
            }
            Self.applyDragSettings(config.config, to: drags)
            drags.screenZones = { [unowned self] screen in self.zones(on: screen) }
            commander.screenZones = { [unowned self] screen in self.zones(on: screen, keyboard: true) }
            commander.isParked = { [unowned self] id in self.workspaces.state.isHidden(id) }
            commander.ruleZones = { [unowned self] screen in self.zones(on: screen, quiet: true) }
            arrangements.bundleID = { [unowned self] pid in self.bundleID(pid) }
            arrangements.isPlaceable = { [unowned self] w in self.commander.rule(w).refusal(for: w, via: .hotkey) == nil
            }
            arrangements.screenZones = { [unowned self] screen in self.zones(on: screen, quiet: true) }
            arrangements.zonesOf = { [unowned self] window, screen in
                guard let z = self.zones(on: screen, quiet: true) else { return nil }
                return z.layout.zones(matching: window.frame, in: screen.visibleFrame, gaps: z.gaps)
            }
            arrangements.isTiledWorkspace = { [unowned self] n in self.tiling.isTiledWorkspace(n) }
            arrangements.onChange = { [weak self] in self?.rebuildArrangementsMenu() }
            rebuildArrangementsMenu()
            config.onStatusChange = { [weak self] in self?.refresh() }
            config.onChange = { [weak self] in self?.apply($0) }
            config.start()
            updates.onChange = { [weak self] in
                self?.refresh()
                if self?.windows.isSettingsVisible == true { self?.updateSettingsModel() }
            }
            applyUpdates(config.config)
            startRemap()
            workspaces.setEnabled(config.config.workspacesEnabled)
            workspaces.start()  // before the registry: recovers windows parked by a crash
            registry.start()
            registry.whenReady { [weak self] in
                self?.startTaskbar()
                self?.switcher.prewarm()
                self?.switcher.requestPreviewPermission()
            }
            startHotkeys()
            startIPC()
            refresh()
        } else {
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startWhenTrusted()
            }
        }
    }
}
