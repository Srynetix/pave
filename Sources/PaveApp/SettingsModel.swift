// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// What the Settings and About windows show, and what they can do. The
/// AppDelegate refreshes it (`update`) and provides the actions; every change
/// goes through the config file, which stays the single source of truth.
@MainActor
final class SettingsModel: ObservableObject {
    struct WorkspaceRow: Identifiable, Equatable {
        let id: Int
        var name: String
        /// From `workspaces.icons` ("" for none).
        var icon: String = ""
        /// Index in `screens` of the screen it lives on (nil: none yet).
        var screen: Int?
        var visible: Bool
        var windows: Int
    }

    struct ScreenChoice: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    /// A connected screen and its zone layout.
    struct ZoneScreenRow: Identifiable, Equatable {
        /// Index in `Screens.all()`.
        let id: Int
        let name: String
        /// The `[zones.screens]` key naming it, or the one that would be written.
        let key: String
        /// Its layout in the config ("none" when it has none).
        let layout: String
    }

    struct KeyboardRow: Identifiable, Equatable {
        let id: String  // KeyRemap.Keyboard.configID
        let name: String
        let state: String
        let remapped: Bool
    }

    /// An open window of an app (title rules: suggestions and matches).
    /// Titles stay in memory, never logged.
    struct OpenWindow: Hashable {
        let title: String
        let workspace: Int
    }

    struct RunningApp: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
    }

    enum Login: Equatable { case devCopy, off, on, needsApproval }

    struct Status: Equatable {
        var trusted = false
        var screenRecording = false
        var windows = 0
        var apps = 0
        var hung: [String] = []
        var screens: [String] = []
        var keyboard = ""
        var configPath = ""
        var configState = ""
        var configError: String?
        var nativeTiling = false
        var stageManager = false
        var login = Login.devCopy
        /// The "pc" remap is active: shortcuts are shown as the keys pressed.
        var pcKeys = false
        /// Updates: a line, the newer version found, a check or install running.
        var update = ""
        var updateAvailable: String?
        var updateBusy = false
        /// The installed copy (a dev build does not update itself).
        var canUpdate = false
    }

    @Published private(set) var config = PaveConfig.default
    @Published private(set) var status = Status()
    @Published private(set) var workspaces: [WorkspaceRow] = []
    @Published private(set) var screens: [ScreenChoice] = []
    @Published private(set) var keyboards: [KeyboardRow] = []
    @Published private(set) var zoneScreens: [ZoneScreenRow] = []
    @Published private(set) var runningApps: [RunningApp] = []
    /// The section shown in the Settings window.
    @Published var section: SettingsView.Section = .general
    /// The app rule to scroll to (taskbar "Pin by Window Title…").
    @Published var focusedRule: String?
    /// A change the file refused (shown at the top of the window).
    @Published var lastError: String?

    // Shortcut recording.
    @Published private(set) var recording: HotkeyAction?
    @Published var conflict: (action: HotkeyAction, hotkey: Hotkey, other: HotkeyAction)?
    private var keyMonitor: Any?

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let commit = Bundle.main.object(forInfoDictionaryKey: "PaveCommit") as? String ?? String(localized: "dev build")

    // Provided by the AppDelegate.
    var setValue: (_ table: String, _ key: String, _ value: String, _ logValue: Bool) -> String? = { _, _, _, _ in nil }
    var removeValue: (_ table: String, _ key: String) -> String? = { _, _ in nil }
    var removeTable: (_ table: String) -> String? = { _ in nil }
    /// Keys that are part of a window title: never logged.
    var setPrivateKey: (_ table: String, _ key: String, _ value: String) -> String? = { _, _, _ in nil }
    var removePrivateKey: (_ table: String, _ key: String) -> String? = { _, _ in nil }
    var setLogin: (Bool) -> Void = { _ in }
    var toggleNativeTiling: () -> Void = {}
    var displayWorkspace: (_ n: Int, _ screen: Int) -> Void = { _, _ in }
    var pauseHotkeys: (Bool) -> Void = { _ in }
    var perform: (_ action: Action) -> Void = { _ in }
    var restart: () -> Void = {}
    /// Fresh status now (the welcome guide watches the permissions).
    var requestRefresh: () -> Void = {}
    /// The open standard windows of an app, by bundle ID.
    var windowTitles: (_ bundleID: String) -> [OpenWindow] = { _ in [] }
    /// Uses a layout on a screen (windows in zones follow it).
    var assignZoneLayout: (_ screen: Int, _ layout: String) -> Void = { _, _ in }
    /// Opens the zone editor on a screen (nil: under the mouse), from a layout (nil: the screen's).
    var editZones: (_ screen: Int?, _ layout: String?) -> Void = { _, _ in }

    enum Action {
        case openConfig, revealConfig, showLogs, reapplyRemap, restoreAll, accessibility, screenRecording, stageManager,
            onboarding, checkUpdates
    }

    func update(
        config: PaveConfig, status: Status, workspaces: [WorkspaceRow], screens: [ScreenChoice],
        keyboards: [KeyboardRow], runningApps: [RunningApp]
    ) {
        if self.config != config { self.config = config }
        if self.status != status { self.status = status }
        if self.workspaces != workspaces { self.workspaces = workspaces }
        if self.screens != screens { self.screens = screens }
        if self.keyboards != keyboards { self.keyboards = keyboards }
        if self.runningApps != runningApps { self.runningApps = runningApps }
    }

    func updateZones(_ rows: [ZoneScreenRow]) {
        if zoneScreens != rows { zoneScreens = rows }
    }

    // MARK: - Changes (through the file)

    /// Workspace `n` uses `layout` on screens that have one; nil: the screen's.
    func setWorkspaceZones(_ n: Int, _ layout: String?) {
        if let layout {
            apply(setValue("zones.workspaces", "\(n)", ConfigEdit.string(layout), true))
        } else {
            apply(removeValue("zones.workspaces", "\(n)"))
        }
    }

    /// A user layout used by no screen and no workspace can go.
    func isZoneLayoutUsed(_ name: String) -> Bool {
        config.zones.screens.values.contains(name) || config.zones.workspaces.values.contains(name)
    }

    func deleteZoneLayout(_ name: String) {
        apply(removeTable("layouts.\"\(name)\""))
    }

    private func apply(_ problem: String?) {
        lastError = problem.map { String(localized: "Setting not saved: \($0)") }
    }

    func set(_ table: String, _ key: String, _ value: Bool) {
        apply(setValue(table, key, value ? "true" : "false", true))
    }

    func set(_ table: String, _ key: String, string value: String) {
        apply(setValue(table, key, ConfigEdit.string(value), true))
    }

    func setTiled(_ n: Int, _ on: Bool) {
        var list = config.tilingWorkspaces
        if on { list.insert(n) } else { list.remove(n) }
        apply(setValue("workspaces", "tiling", ConfigEdit.list(list.sorted()), true))
    }

    func setValueAndApply(_ table: String, _ key: String, _ value: String) {
        apply(setValue(table, key, value, true))
    }

    func setGaps(_ gaps: Int) {
        guard gaps != config.tilingGaps else { return }
        apply(setValue("workspaces", "gaps", "\(gaps)", true))
    }

    /// Names may hold a customer's name: never logged.
    func setName(_ n: Int, _ name: String) {
        var names = config.workspaceNames
        while names.count < n { names.append("") }
        names[n - 1] = name.trimmingCharacters(in: .whitespaces)
        while names.last?.isEmpty == true { names.removeLast() }
        guard names != config.workspaceNames else { return }
        apply(
            names.isEmpty
                ? removeValue("workspaces", "names") : setValue("workspaces", "names", ConfigEdit.list(names), false))
    }

    /// Icons may hint at a customer, as names: never logged. An invalid one
    /// is refused (the field shows it).
    @discardableResult
    func setIcon(_ n: Int, _ icon: String) -> Bool {
        let icon = icon.trimmingCharacters(in: .whitespaces)
        guard WorkspaceIcon.isValid(icon) else { return false }
        var icons = config.workspaceIcons
        while icons.count < n { icons.append("") }
        icons[n - 1] = icon
        while icons.last?.isEmpty == true { icons.removeLast() }
        guard icons != config.workspaceIcons else { return true }
        apply(
            icons.isEmpty
                ? removeValue("workspaces", "icons") : setValue("workspaces", "icons", ConfigEdit.list(icons), false))
        return true
    }

    func setPinned(_ list: [String]) {
        apply(setValue("taskbar", "pinned", ConfigEdit.list(list), true))
    }

    func setSkipped(_ keyboard: String, _ skipped: Bool) {
        var list = config.keyboardSkip
        if skipped { list.insert(keyboard) } else { list.remove(keyboard) }
        apply(
            list.isEmpty
                ? removeValue("keyboard", "skip") : setValue("keyboard", "skip", ConfigEdit.list(list.sorted()), true))
    }

    // MARK: App rules

    func rule(_ bundleID: String) -> AppRule { config.appRules[bundleID] ?? AppRule() }

    func setRule(_ bundleID: String, _ key: String, _ value: String?) {
        let table = ConfigEdit.appTable(bundleID)
        apply(value.map { setValue(table, key, $0, true) } ?? removeValue(table, key))
        // A rule left with no key: its table goes too.
        if config.appRules[bundleID] == AppRule() { apply(removeTable(table)) }
    }

    /// `[apps."…".titles]`: new windows whose title matches `pattern` open
    /// on `workspace` (nil: the pattern goes).
    func setTitleRule(_ bundleID: String, _ pattern: String, _ workspace: Int?) {
        let table = ConfigEdit.appTable(bundleID) + ".titles"
        if let workspace {
            apply(setPrivateKey(table, pattern, "\(workspace)"))
        } else {
            apply(removePrivateKey(table, pattern))
            if rule(bundleID).titles.isEmpty { apply(removeTable(table)) }
        }
        if config.appRules[bundleID] == AppRule() { apply(removeTable(ConfigEdit.appTable(bundleID))) }
    }

    /// Renames a title pattern, keeping its workspace.
    func renameTitleRule(_ bundleID: String, from old: String, to new: String) {
        guard old != new, !new.isEmpty, let n = rule(bundleID).titles[old], rule(bundleID).titles[new] == nil else {
            return
        }
        apply(setPrivateKey(ConfigEdit.appTable(bundleID) + ".titles", new, "\(n)"))
        apply(removePrivateKey(ConfigEdit.appTable(bundleID) + ".titles", old))
    }

    func addRule(_ bundleID: String) {
        // `tile = true` is the default: the table exists, nothing changes yet.
        apply(setValue(ConfigEdit.appTable(bundleID), "tile", "true", true))
    }

    func deleteRule(_ bundleID: String) {
        apply(removeTable(ConfigEdit.appTable(bundleID)))
    }

    func appName(_ bundleID: String) -> String {
        if let running = runningApps.first(where: { $0.bundleID == bundleID }) { return running.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    func appIcon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    // MARK: Language

    /// The interface language: macOS's (the default), or one chosen here. It
    /// is Pavé's own `AppleLanguages` default, read once at launch.
    enum Language: String {
        case system
        case english = "en"
        case french = "fr"
    }

    private static let launchLanguage = Language.current
    @Published private(set) var language = Language.current

    var languageNeedsRestart: Bool { language != Self.launchLanguage }

    func setLanguage(_ new: Language) {
        if new == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([new.rawValue], forKey: "AppleLanguages")
        }
        language = new
    }

    // MARK: Shortcuts

    func hotkey(_ action: HotkeyAction) -> Hotkey? { config.bindings[action] ?? nil }

    /// A shortcut as the user presses it (with the "pc" preset, ⌃ is the ⌘ key).
    func label(_ hotkey: Hotkey) -> String {
        (status.pcKeys ? hotkey.pressedWithPCPreset : hotkey).description
    }

    /// The key that drives Pavé's shortcuts, as printed on the keyboard.
    var mainKey: String { status.pcKeys ? "⌘" : "⌃" }

    func startRecording(_ action: HotkeyAction) {
        stopRecording()
        recording = action
        conflict = nil
        // Pavé's own shortcuts would swallow the keys being recorded.
        pauseHotkeys(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.recorded(event) }
            return nil
        }
    }

    func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if recording != nil { pauseHotkeys(false) }
        recording = nil
    }

    private func recorded(_ event: NSEvent) {
        guard let action = recording else { return }
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        switch (event.keyCode, modifiers.isEmpty) {
        case (53, true): stopRecording()  // Escape: cancel
        case (51, true), (117, true):  // Delete: no shortcut
            stopRecording()
            bind(action, nil)
        case (_, true): NSSound.beep()  // a shortcut needs a modifier
        default:
            let hotkey = Hotkey(event.keyCode, modifiers)
            stopRecording()
            if let other = HotkeyAction.all.first(where: { $0 != action && (config.bindings[$0] ?? nil) == hotkey }) {
                conflict = (action, hotkey, other)
            } else {
                bind(action, hotkey)
            }
        }
    }

    /// The conflicting shortcut moves to `action`; the other one has none.
    func replaceConflict() {
        guard let conflict else { return }
        self.conflict = nil
        bind(conflict.other, nil)
        bind(conflict.action, conflict.hotkey)
    }

    func bind(_ action: HotkeyAction, _ hotkey: Hotkey?) {
        apply(setValue("bindings", action.configName, ConfigEdit.string(hotkey?.configName ?? "none"), true))
    }
}

extension HotkeyAction {
    /// Label in the Settings window.
    var label: String {
        switch self {
        case .layout(.snapLeft): String(localized: "Left half")
        case .layout(.snapRight): String(localized: "Right half")
        case .layout(.maximize): String(localized: "Maximize")
        case .layout(.restore): String(localized: "Restore")
        case .layout(.moveToScreenLeft): String(localized: "To the left screen")
        case .layout(.moveToScreenRight): String(localized: "To the right screen")
        case .switcher: String(localized: "Switcher")
        case .switcherSameApp: String(localized: "Switcher, same app")
        case .workspace(let n): String(localized: "Show workspace \(n)")
        case .moveToWorkspace(let n): String(localized: "Send the window to \(n)")
        case .focus(.left): String(localized: "Focus left")
        case .focus(.right): String(localized: "Focus right")
        case .focus(.up): String(localized: "Focus up")
        case .focus(.down): String(localized: "Focus down")
        case .resize(.left): String(localized: "Resize left")
        case .resize(.right): String(localized: "Resize right")
        case .resize(.up): String(localized: "Resize up")
        case .resize(.down): String(localized: "Resize down")
        case .toggleFloating: String(localized: "Floating ⇄ tiled")
        case .zonePicker: String(localized: "Zone layouts")
        case .arrangementPicker: String(localized: "Window arrangements")
        }
    }
}

extension SettingsModel.Language {
    static var current: Self {
        guard
            UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"]
                != nil,
            let first = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first
        else { return .system }
        return first.hasPrefix("fr") ? .french : .english
    }
}
