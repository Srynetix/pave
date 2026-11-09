/// Pavé's configuration (`~/.config/pave/config.toml`).
///
/// Every setting has a default equal to the current behaviour, so a missing
/// file, or a file that only sets a few keys, is fine. Pure: PaveMac reads the
/// file, watches it and applies the result.
public struct PaveConfig: Equatable, Sendable {
    /// Virtual workspaces. Off by default: when off, the workspace hotkeys are not grabbed at all.
    public var workspacesEnabled = false
    /// Names of workspaces 1, 2…, shown in the taskbar's tooltips.
    /// Never logged: a name may be a customer's.
    public var workspaceNames: [String] = []
    /// `workspaces.icons`: drawn in the taskbar instead of the numbers ("" keeps one).
    public var workspaceIcons: [String] = []
    /// Workspaces tiled: `[workspaces] tiling = [2, 3]`.
    public var tilingWorkspaces: Set<Int> = []
    /// Points between tiles and around them.
    public var tilingGaps = 8
    /// What the switcher lists.
    public var switcherScope: SwitcherScope = .workspace
    /// Shortcut of every action; nil = unbound.
    public var bindings: [HotkeyAction: Hotkey?]
    /// Pavé remaps the keyboards with hidutil. Off if Karabiner is kept.
    public var keyboardRemap = true
    public var keyboardPreset: KeyRemap.Preset = .pc
    /// Keyboards left untouched, by `KeyRemap.Keyboard.configID` ("1133:45944", "built-in").
    public var keyboardSkip: Set<String> = []
    /// Taskbar: one entry per window by default, pinned apps by bundle ID.
    /// Off by default: the Dock stays the user's bar until the taskbar is turned on.
    public var taskbarEnabled = false
    /// Hide the Dock while the taskbar replaces it. Only
    /// applied when the taskbar is on; the Dock settings are always restored.
    public var taskbarHideDock = false
    public var taskbarGrouping: TaskbarGrouping = .never
    /// Left ⌥ tapped alone opens the launcher (the Windows key).
    public var taskbarOptionOpensLauncher = true
    public var taskbarPinned: [String] = []
    /// Per-app rules, by bundle ID (`[apps."com.example.app"]`).
    public var appRules: [String: AppRule] = [:]
    /// `[zones]` and `[layouts."<name>"]`: FancyZones-style layouts.
    public var zones = ZoneSettings()
    /// `windows.magnet`: a window dropped this close (points) to another
    /// window's edge or the screen's sticks to it; 0: off.
    public var windowMagnet = 12
    /// `windows.magnet-fill`: stuck against another window, it also fills
    /// the free space there.
    public var magnetFill = true
    /// `windows.resize-neighbours`: resizing by an edge another window
    /// touches resizes that one too.
    public var resizeNeighbours = true
    /// `[updates]`: look for a newer Pavé at launch and once a day.
    public var updatesCheck = true
    /// The GitHub repository whose releases Pavé updates from (`owner/repo`).
    public var updatesSource = Updates.defaultSource

    public func rule(for bundleID: String?) -> AppRule {
        bundleID.flatMap { appRules[$0] } ?? AppRule()
    }

    public enum SwitcherScope: String, Sendable, CaseIterable {
        /// Windows of the visible workspace(s) only.
        case workspace
        /// Windows shown on the screen in use (the focused window's).
        case screen
        case all
    }

    public init(bindings: [HotkeyAction: Hotkey?] = Self.defaultBindings) {
        self.bindings = bindings
    }

    public static let `default` = PaveConfig()

    /// Win+arrows and Win+N on a PC keyboard = ⌃ with the "pc" keyboard remapping.
    public static let defaultBindings: [HotkeyAction: Hotkey?] = {
        var result: [HotkeyAction: Hotkey?] = [
            .layout(.snapLeft): Hotkey(Hotkey.Key.leftArrow, .control),
            .layout(.snapRight): Hotkey(Hotkey.Key.rightArrow, .control),
            .layout(.maximize): Hotkey(Hotkey.Key.upArrow, .control),
            .layout(.restore): Hotkey(Hotkey.Key.downArrow, .control),
            .layout(.moveToScreenLeft): Hotkey(Hotkey.Key.leftArrow, [.control, .shift]),
            .layout(.moveToScreenRight): Hotkey(Hotkey.Key.rightArrow, [.control, .shift]),
            // DockDoor's shortcut; masks "next tab" in apps, as DockDoor does.
            .switcher: Hotkey(Hotkey.Key.tab, .control),
            // Off by default: ⌃` toggles the integrated terminal in VS Code.
            .switcherSameApp: nil,
        ]
        for n in Workspaces.range {
            result[.workspace(n)] = Hotkey(Hotkey.Key.digits[n - 1], .control)
            result[.moveToWorkspace(n)] = Hotkey(Hotkey.Key.digits[n - 1], [.control, .shift])
        }
        // Tiling: ⌃⌥ + arrows move the focus, ⌃⌥⇧ + arrows resize.
        let arrows: [(Direction, UInt16)] = [
            (.left, Hotkey.Key.leftArrow), (.right, Hotkey.Key.rightArrow),
            (.up, Hotkey.Key.upArrow), (.down, Hotkey.Key.downArrow),
        ]
        for (direction, key) in arrows {
            result[.focus(direction)] = Hotkey(key, [.control, .option])
            result[.resize(direction)] = Hotkey(key, [.control, .option, .shift])
        }
        result[.toggleFloating] = Hotkey(49, [.control, .shift])
        result[.zonePicker] = Hotkey(Hotkey.Key.z, [.control, .shift])
        result[.arrangementPicker] = Hotkey(Hotkey.Key.a, [.control, .shift])
        return result
    }()

    /// The hotkeys to grab: workspace actions are left out while workspaces are off.
    public var activeBindings: [Hotkey: HotkeyAction] {
        var result: [Hotkey: HotkeyAction] = [:]
        for (action, hotkey) in bindings {
            guard let hotkey else { continue }
            if !workspacesEnabled, action.isWorkspaceAction { continue }
            if !zones.enabled, action == .zonePicker { continue }
            result[hotkey] = action
        }
        return result
    }

    // MARK: - Parsing

    public struct Problem: Error, Equatable, Sendable, CustomStringConvertible {
        /// 0 when the problem is not tied to a line.
        public var line: Int
        public var message: String
        public var description: String { line > 0 ? "line \(line): \(message)" : message }
    }

    /// Parses a config file. Errors (bad syntax, wrong type, invalid or
    /// duplicated shortcut) make the whole file invalid: the caller keeps the
    /// previous config. Unknown keys are only warnings (typos stay visible
    /// without breaking the rest).
    public static func parse(_ text: String) throws(Problem) -> (config: PaveConfig, warnings: [Problem]) {
        let root: [String: TOMLValue]
        let lines: [String: Int]
        do {
            (root, lines) = try TOML.parse(text)
        } catch {
            throw Problem(line: error.line, message: error.message)
        }
        var config = PaveConfig()
        var warnings: [Problem] = []
        func line(_ path: String) -> Int { lines[path] ?? 0 }

        func table(_ name: String) throws(Problem) -> [String: TOMLValue] {
            switch root[name] {
            case nil: return [:]
            case .table(let t): return t
            case let other?: throw Problem(line: line(name), message: "'\(name)' must be a [\(name)] table, not a \(other.typeName)")
            }
        }

        for key in root.keys.sorted() where !["workspaces", "switcher", "keyboard", "taskbar", "zones", "layouts", "apps", "bindings", "updates", "windows"].contains(key) {
            warnings.append(Problem(line: line(key), message: "unknown setting '\(key)', ignored"))
        }

        /// Every key of a table, in order; `read` returns false for a key it
        /// does not know (a warning, not an error: typos stay visible).
        func section(_ name: String, _ read: (String, ConfigField) throws(Problem) -> Bool) throws(Problem) {
            for (key, value) in try table(name).sorted(by: { $0.key < $1.key }) {
                let path = "\(name).\(key)"
                if try !read(key, ConfigField(path: path, value: value, line: line(path))) {
                    warnings.append(Problem(line: line(path), message: "unknown setting '\(path)', ignored"))
                }
            }
        }
        let points = "a number of points from 0 to 64"

        try section("workspaces") { key, field throws(Problem) in
            switch key {
            case "enabled": config.workspacesEnabled = try field.bool()
            case "tiling":
                let numbers = try field.list("\(field.path) must be a list of workspace numbers like [2, 3] (1 to 9)") { item -> Int? in
                    guard case .integer(let n) = item, Workspaces.range.contains(n) else { return nil }
                    return n
                }
                config.tilingWorkspaces = Set(numbers)
            case "gaps": config.tilingGaps = try field.integer(in: 0...64, points)
            case "names":
                config.workspaceNames = try field.list(
                    "\(field.path) must be a list of names like [\"Web\", \"Code\"] (workspaces 1, 2…)", maxCount: Workspaces.range.count
                ) { item -> String? in
                    guard case .string(let name) = item else { return nil }
                    return name
                }
            case "icons":
                // The values are not shown: they may hint at a customer, as names.
                config.workspaceIcons = try field.list(
                    "\(field.path) must be a list of emoji, up to \(WorkspaceIcon.maxCharacters) letters, \"sf:<symbol>\" or \"\" (workspaces 1, 2…)",
                    maxCount: Workspaces.range.count
                ) { item -> String? in
                    guard case .string(let icon) = item, WorkspaceIcon.isValid(icon) else { return nil }
                    return icon.trimmingCharacters(in: .whitespaces)
                }
            default: return false
            }
            return true
        }

        try section("switcher") { key, field throws(Problem) in
            guard key == "scope" else { return false }
            config.switcherScope = try field.choice(SwitcherScope.self, allowed: SwitcherScope.allCases.map(\.rawValue).quotedChoices)
            return true
        }

        try section("keyboard") { key, field throws(Problem) in
            switch key {
            case "remap": config.keyboardRemap = try field.bool()
            case "preset": config.keyboardPreset = try field.choice(KeyRemap.Preset.self, allowed: KeyRemap.Preset.allCases.map(\.rawValue).quotedChoices)
            case "skip":
                let ids = try field.list("\(field.path) must be a list like [\"built-in\", \"1133:45944\"]") { item -> String? in
                    guard case .string(let id) = item, id == "built-in" || Self.isVendorProduct(id) else { return nil }
                    return id
                }
                config.keyboardSkip = Set(ids)
            default: return false
            }
            return true
        }

        try section("taskbar") { key, field throws(Problem) in
            switch key {
            case "enabled": config.taskbarEnabled = try field.bool()
            case "hide-dock": config.taskbarHideDock = try field.bool()
            case "start-key": config.taskbarOptionOpensLauncher = try field.string(oneOf: ["option", "none"], allowed: "\"option\" or \"none\"") == "option"
            case "grouping":
                config.taskbarGrouping = try field.choice(
                    TaskbarGrouping.self, allowed: "one of " + TaskbarGrouping.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))
            case "pinned":
                var ids: [String] = []
                for id in try field.list("\(field.path) must be a list of bundle IDs like [\"com.apple.finder\"]", { item -> String? in
                    guard case .string(let id) = item, !id.isEmpty else { return nil }
                    return id
                }) where !ids.contains(id) { ids.append(id) }
                config.taskbarPinned = ids
            default: return false
            }
            return true
        }

        // [layouts."<name>"], before [zones] which names them.
        for (name, value) in try table("layouts").sorted(by: { $0.key < $1.key }) {
            let path = "layouts.\(name)"
            let usage = "layouts.\"\(name)\".zones must be a list of [x, y, width, height] in percent, like [[0, 0, 50, 100], [50, 0, 50, 100]]"
            guard case .table(let settings) = value else {
                throw Problem(line: line(path), message: "layouts.\"\(name)\" must be a [layouts.\"\(name)\"] table, not \(value.shown)")
            }
            guard name != ZoneSettings.none, !name.isEmpty else {
                throw Problem(line: line(path), message: "\"\(name)\" cannot be a layout name")
            }
            for key in settings.keys.sorted() where key != "zones" {
                warnings.append(Problem(line: line("\(path).\(key)"), message: "unknown setting '\(key)' for layout \(name), ignored"))
            }
            guard case .array(let items)? = settings["zones"] else {
                throw Problem(line: line(settings["zones"] == nil ? path : "\(path).zones"), message: usage)
            }
            var zones: [ZoneLayout.Zone] = []
            for item in items {
                guard case .array(let numbers) = item, numbers.count == 4 else { throw Problem(line: line("\(path).zones"), message: usage) }
                var n: [Int] = []
                for number in numbers {
                    guard case .integer(let i) = number else { throw Problem(line: line("\(path).zones"), message: usage) }
                    n.append(i)
                }
                zones.append(.init(n[0], n[1], n[2], n[3]))
            }
            do {
                config.zones.layouts[name] = try ZoneLayout(name: name, zones: zones)
            } catch {
                throw Problem(line: line("\(path).zones"), message: "layout \"\(name)\": \(error.message)")
            }
        }

        // [zones]
        let layoutNames = (ZoneLayout.builtIn.map(\.name) + config.zones.layouts.keys).sorted()
        func layoutName(_ value: TOMLValue, _ path: String) throws(Problem) -> String {
            guard case .string(let name) = value, name == ZoneSettings.none || config.zones.layout(named: name) != nil else {
                let allowed = (layoutNames + [ZoneSettings.none]).map { "\"\($0)\"" }.joined(separator: ", ")
                throw Problem(line: line(path), message: "\(path) must be a layout: \(allowed), not \(value.shown)")
            }
            return name
        }
        try section("zones") { key, field throws(Problem) in
            switch key {
            case "enabled": config.zones.enabled = try field.bool()
            case "keyboard": config.zones.keyboard = try field.bool()
            case "gaps": config.zones.gaps = try field.integer(in: 0...64, points)
            case "show": config.zones.show = try field.choice(ZoneSettings.Show.self, allowed: ZoneSettings.Show.allCases.map(\.rawValue).quotedChoices)
            case "screens":
                guard case .table(let screens) = field.value else {
                    throw field.problem("\(field.path) must be a [zones.screens] table, like builtin = \"none\"")
                }
                for (screen, name) in screens.sorted(by: { $0.key < $1.key }) {
                    config.zones.screens[screen] = try layoutName(name, "\(field.path).\(screen)")
                }
            case "workspaces":
                guard case .table(let workspaces) = field.value else {
                    throw field.problem("\(field.path) must be a [zones.workspaces] table, like 3 = \"thirds\"")
                }
                for (number, name) in workspaces.sorted(by: { $0.key < $1.key }) {
                    guard let n = Int(number), Workspaces.range.contains(n) else {
                        throw Problem(line: line("\(field.path).\(number)"), message: "\(field.path): '\(number)' is not a workspace number from 1 to 9")
                    }
                    config.zones.workspaces[n] = try layoutName(name, "\(field.path).\(number)")
                }
            default: return false
            }
            return true
        }

        // [apps."<bundle id>"]
        for (bundleID, value) in try table("apps").sorted(by: { $0.key < $1.key }) {
            let path = "apps.\(bundleID)"
            guard case .table(let settings) = value else {
                throw Problem(line: line(path), message: "apps.\"\(bundleID)\" must be a [apps.\"\(bundleID)\"] table, not \(value.shown)")
            }
            var rule = AppRule()
            for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
                let keyPath = "\(path).\(key)"
                if key == "taskbar-overlap" {
                    guard case .string(let mode) = value, ["allow", "fix"].contains(mode) else {
                        throw Problem(line: line(keyPath), message: "apps.\"\(bundleID)\".taskbar-overlap must be \"allow\" or \"fix\", not \(value.shown)")
                    }
                    rule.taskbarOverlap = mode == "allow"
                    continue
                }
                if key == "zone" {
                    guard case .integer(let n) = value, (1...ZoneLayout.maxZones).contains(n) else {
                        throw Problem(line: line(keyPath), message: "apps.\"\(bundleID)\".zone must be a zone number from 1 to \(ZoneLayout.maxZones), not \(value.shown)")
                    }
                    rule.zone = n
                    continue
                }
                if key == "profiles" {
                    guard case .table(let profiles) = value else {
                        throw Problem(line: line(keyPath), message: "apps.\"\(bundleID)\".profiles must be a [apps.\"\(bundleID)\".profiles] table, not \(value.shown)")
                    }
                    for (profile, value) in profiles {
                        // The profile's name is not shown: the line is enough.
                        guard !profile.isEmpty, case .integer(let n) = value, Workspaces.range.contains(n) else {
                            throw Problem(line: line("\(keyPath).\(profile)"), message: "apps.\"\(bundleID)\".profiles: each profile needs a workspace number from 1 to 9, not \(value.shown)")
                        }
                        rule.profiles[profile] = n
                    }
                    continue
                }
                if key == "workspace" {
                    guard case .integer(let n) = value, Workspaces.range.contains(n) else {
                        throw Problem(line: line(keyPath), message: "apps.\"\(bundleID)\".workspace must be a number from 1 to 9, not \(value.shown)")
                    }
                    rule.workspace = n
                    continue
                }
                guard case .bool(let b) = value, ["ignore", "drag-snap", "tile"].contains(key) else {
                    if ["ignore", "drag-snap", "tile"].contains(key) {
                        throw Problem(line: line(keyPath), message: "apps.\"\(bundleID)\".\(key) must be true or false, not \(value.shown)")
                    }
                    warnings.append(Problem(line: line(keyPath), message: "unknown setting '\(key)' for app \(bundleID), ignored"))
                    continue
                }
                switch key {
                case "ignore": rule.ignore = b
                case "tile": rule.tile = b
                default: rule.dragSnap = b
                }
            }
            config.appRules[bundleID] = rule
        }

        // [windows]
        try section("windows") { key, field throws(Problem) in
            switch key {
            case "magnet": config.windowMagnet = try field.integer(in: 0...64, points)
            case "resize-neighbours": config.resizeNeighbours = try field.bool()
            case "magnet-fill": config.magnetFill = try field.bool()
            default: return false
            }
            return true
        }

        // [updates]
        try section("updates") { key, field throws(Problem) in
            switch key {
            case "check": config.updatesCheck = try field.bool()
            case "source":
                guard case .string(let source) = field.value, Updates.isValidSource(source) else {
                    throw field.problem("\(field.path) must be a GitHub repository like \"owner/repo\", not \(field.value.shown)")
                }
                config.updatesSource = source
            default: return false
            }
            return true
        }

        // [bindings]: only the listed actions change, the others keep their default.
        for (key, value) in try table("bindings").sorted(by: { $0.key < $1.key }) {
            let path = "bindings.\(key)"
            guard let action = HotkeyAction(configName: key) else {
                warnings.append(Problem(line: line(path), message: "unknown action '\(key)', ignored"))
                continue
            }
            guard case .string(let text) = value else {
                throw Problem(line: line(path), message: "\(path) must be a string like \"ctrl+left\" or \"none\", not \(value.shown)")
            }
            do {
                config.bindings[action] = .some(try Hotkey.parse(text))
            } catch {
                throw Problem(line: line(path), message: "\(path): \(error.message)")
            }
        }

        // The same shortcut for two actions: refuse, rather than pick one silently.
        var owner: [Hotkey: HotkeyAction] = [:]
        for action in HotkeyAction.all {
            guard let hotkey = config.bindings[action] ?? nil else { continue }
            if let other = owner[hotkey] {
                let at = max(line("bindings.\(action.configName)"), line("bindings.\(other.configName)"))
                throw Problem(
                    line: at,
                    message: "\(hotkey.configName) is bound to both \(other.configName) and \(action.configName)")
            }
            owner[hotkey] = action
        }
        return (config, warnings)
    }

    /// "1133:45944": two decimal numbers.
    static func isVendorProduct(_ id: String) -> Bool {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    // MARK: - Template

    /// Written to `~/.config/pave/config.toml` when it does not exist. Parsing
    /// it gives exactly `PaveConfig.default` (checked by a test).
    public static var template: String {
        var text = """
            # Pavé configuration. Changes are applied as soon as the file is saved.
            # Every line is optional: a missing setting keeps its default value.
            # Errors are shown in Pavé's menu and Settings; the previous configuration stays active.

            [workspaces]
            # Virtual workspaces (Win+1..9, Win+Shift+1..9). Off by default.
            # When off, ctrl+1..9 are left to the apps.
            enabled = false
            # Names of workspaces 1, 2… shown when hovering their number in the taskbar.
            # names = ["Web", "Code", "Mail"]
            # Drawn in the taskbar instead of the numbers: an emoji, up to 2 letters,
            # or an SF Symbol ("sf:<name>", see Apple's SF Symbols app). "" keeps the number.
            # icons = ["🌐", "sf:chevron.left.forwardslash.chevron.right", "✉️"]
            # Tiled workspaces (the others float), and the points between tiles.
            # tiling = [2, 3]
            gaps = 8

            [switcher]
            # Windows listed by the switcher: "workspace" (visible workspace only), "screen" (the screen in use) or "all".
            scope = "workspace"

            [keyboard]
            # Pavé remaps the keyboard modifiers (see the README). Set to false if you
            # keep Karabiner-Elements: Pavé then leaves the keyboards alone.
            remap = true
            # "pc": PC habits on Mac keyboards (Win = ctrl, Alt Gr = right cmd, §/< swapped).
            # "none": stock keyboards.
            preset = "pc"
            # Keyboards left untouched: "built-in", or "vendor:product" as listed by
            # `pave keyboards`, e.g. skip = ["1133:45944"].
            skip = []

            [taskbar]
            # Pavé's taskbar at the bottom of each screen (off by default).
            enabled = false
            # Hide the Dock while the taskbar is on (its settings are restored when
            # this is turned off or Pavé quits; after a crash: `pave restore-dock`).
            hide-dock = false
            # "option": tapping left ⌥ alone opens the launcher (Windows key); "none".
            start-key = "option"
            # Entries: "never" (one per window), "always" (one per app), or "when_full".
            grouping = "never"
            # Pinned apps, by bundle ID (`pave apps` lists them), in display order.
            pinned = []

            [zones]
            # Your own layouts of zones, FancyZones style: windows dragged onto a screen
            # that has a layout go into a zone (shift: several), instead of halves and
            # quarters. Off by default.
            enabled = false
            # Points along the screen edges and between zones.
            gaps = 8
            # Zones show while dragging: "always", or "ctrl" (only while ctrl is held).
            show = "always"
            # ctrl+left / ctrl+right move between zones on a screen that has a layout.
            keyboard = true
            # Layout of each screen ("builtin", part of its name, or its UUID). Built-in
            # layouts: "focus" (25/50/25), "thirds", "main-and-stack", "halves", "grid";
            # "none" keeps halves and quarters.
            #   [zones.screens]
            #   builtin = "none"
            #   LG = "focus"
            # Another layout for a workspace, on the screens that have one:
            #   [zones.workspaces]
            #   3 = "main-and-stack"
            # Your layouts: zones as [x, y, width, height], in percent of the screen.
            #   [layouts."Coding"]
            #   zones = [[0, 0, 30, 100], [30, 0, 45, 100], [75, 0, 25, 60], [75, 60, 25, 40]]

            [windows]
            # A window dropped this close (points) to another window's edge or the
            # screen's sticks to it; 0: off. ⌥ while dragging: no magnet.
            magnet = 12
            # Stuck against another window, it also fills the free space there
            # (a window on the right 2/3: one dropped against it fills the first third).
            magnet-fill = true
            # Resizing a window by an edge another window touches resizes that one too.
            resize-neighbours = true

            [updates]
            # Look for a newer Pavé at launch and once a day (nothing is installed
            # without asking). Releases are read with the GitHub CLI (gh).
            check = true
            # The GitHub repository Pavé updates from.
            source = "Srynetix/pave"

            # Per-app rules, by bundle ID (`pave apps` lists those of the running apps):
            #   [apps."com.example.app"]
            #   ignore = true      # Pavé never places its windows (keys, drags)
            #   drag-snap = false  # keys only: dragging it to an edge does not snap
            #   taskbar-overlap = "allow"  # may cover the taskbar (default "fix")
            #   workspace = 3      # its new windows open on workspace 3
            #   [apps."com.brave.Browser".profiles]  # browsers: by profile, from the
            #   Work = 3                             # window title ("… - Brave - Work")
            #   tile = false       # always floating, even on a tiled workspace
            # Dialogs, sheets and panels are never placed, whatever the rules.

            [bindings]
            # Shortcuts: modifiers (ctrl, alt, shift, cmd) + a key, e.g. "ctrl+shift+left".
            # Keys: left right up down, 0-9, tab, space, return, escape, grave, f1-f12, a-z...
            # Letters follow the keyboard layout ("z" is the key that types z, on AZERTY too).
            # "none" disables a shortcut. Modifiers are the ones macOS receives, after
            # the keyboard remapping (Win key = ctrl, see the README).
            # switcher: hold ctrl, Tab/shift+Tab/arrows to move, W closes, Q quits,
            # Space searches, release ctrl to switch, Escape cancels. The same key
            # with shift opens it backwards.
            # switcher-same-app (e.g. "ctrl+grave") is off by default: in VS Code,
            # ctrl+` toggles the integrated terminal.

            """
        for action in HotkeyAction.all {
            let hotkey = defaultBindings[action] ?? nil
            text += "\(action.configName) = \"\(hotkey?.configName ?? "none")\"\n"
        }
        return text
    }
}

extension HotkeyAction {
    /// Every action, in config-file order.
    public static let all: [HotkeyAction] =
        [.switcher, .switcherSameApp]
        + LayoutCommand.allCases.map { .layout($0) }
        + Workspaces.range.map { .workspace($0) }
        + Workspaces.range.map { .moveToWorkspace($0) }
        + Direction.allCases.map { .focus($0) }
        + Direction.allCases.map { .resize($0) }
        + [.toggleFloating, .zonePicker, .arrangementPicker]

    /// Name in `[bindings]`: "snap-left", "workspace-3", "move-to-workspace-3"…
    public var configName: String {
        switch self {
        case .layout(let command): command.rawValue
        case .workspace(let n): "workspace-\(n)"
        case .moveToWorkspace(let n): "move-to-workspace-\(n)"
        case .switcher: "switcher"
        case .switcherSameApp: "switcher-same-app"
        case .focus(let d): "focus-\(d.rawValue)"
        case .resize(let d): "resize-\(d.rawValue)"
        case .toggleFloating: "toggle-floating"
        case .zonePicker: "zone-picker"
        case .arrangementPicker: "arrangement-picker"
        }
    }

    public init?(configName: String) {
        guard let action = Self.all.first(where: { $0.configName == configName }) else { return nil }
        self = action
    }

    var isWorkspaceAction: Bool {
        switch self {
        case .layout, .switcher, .switcherSameApp, .zonePicker, .arrangementPicker: false
        // Tiling and directional focus come with the workspaces.
        case .workspace, .moveToWorkspace, .focus, .resize, .toggleFloating: true
        }
    }
}

/// What Pavé may do with one app's windows.
public struct AppRule: Equatable, Sendable {
    /// Never placed: neither by hotkeys nor by dragging.
    public var ignore = false
    /// Dragging to an edge snaps (hotkeys still work when false).
    public var dragSnap = true
    /// `taskbar-overlap = "allow"`: the window may cover the taskbar (not fixed).
    public var taskbarOverlap = false
    /// `workspace = N`: its new windows open on workspace N.
    public var workspace: Int?
    /// `tile = false`: always floating, even on a tiled workspace.
    public var tile = true
    /// `zone = N`: its new windows open in zone N, on a screen that has a layout.
    public var zone: Int?
    /// `[apps."…".profiles]`: workspace of the new windows whose title ends
    /// with " - <profile>" (Brave, Chrome, Edge name the profile there).
    /// Wins over `workspace`, which still covers the other profiles.
    public var profiles: [String: Int] = [:]

    public init(ignore: Bool = false, dragSnap: Bool = true, taskbarOverlap: Bool = false, workspace: Int? = nil) {
        self.ignore = ignore
        self.dragSnap = dragSnap
        self.taskbarOverlap = taskbarOverlap
        self.workspace = workspace
    }

    public enum Via: Sendable { case hotkey, drag }

    /// Where a new window goes, from its title. Titles are compared here,
    /// never logged.
    public struct WorkspaceChoice: Equatable, Sendable {
        public var workspace: Int?
        /// Chosen by its profile.
        public var byProfile = false
        /// No profile matched: the title may still come (a browser names its
        /// window after creating it), worth looking at it again.
        public var awaitsTitle = false

        public init(workspace: Int? = nil, byProfile: Bool = false, awaitsTitle: Bool = false) {
            self.workspace = workspace
            self.byProfile = byProfile
            self.awaitsTitle = awaitsTitle
        }
    }

    public func workspaceChoice(title: String) -> WorkspaceChoice {
        if let n = profileWorkspace(title: title) { return WorkspaceChoice(workspace: n, byProfile: true) }
        return WorkspaceChoice(workspace: workspace, awaitsTitle: !profiles.isEmpty)
    }

    /// The workspace of the profile `title` ends with (the longest name wins:
    /// "Work" and "Home Work").
    public func profileWorkspace(title: String) -> Int? {
        profiles.filter { title.hasSuffix(" - " + $0.key) }.max { $0.key.count < $1.key.count }?.value
    }

    /// Why `window` must not be placed `via` this way, or nil if it may.
    /// Only standard windows are placed: dialogs, sheets and panels never.
    public func refusal(for window: WindowSnapshot, via: Via) -> String? {
        if window.subrole != "AXStandardWindow" { return "not placed: \(window.subrole) (only standard windows)" }
        if ignore { return "ignored by its app rule" }
        if via == .drag, !dragSnap { return "drag-snap off by its app rule" }
        return nil
    }

    /// Short form for `pave dump` / `pave apps`; nil = no rule.
    public var summary: String? {
        let parts = [
            ignore ? "ignore" : nil, !ignore && !dragSnap ? "no drag-snap" : nil, taskbarOverlap ? "taskbar-overlap allow" : nil,
            workspace.map { "workspace \($0)" }, profiles.isEmpty ? nil : "workspace by profile (\(profiles.count))",
            tile ? nil : "no tiling", zone.map { "zone \($0)" },
        ]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
