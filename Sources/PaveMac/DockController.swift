// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore
import PaveIPC

/// Hides the Dock while Pavé's taskbar replaces it (`autohide` + a very long
/// `autohide-delay`), shrunk to its smallest (`tilesize` 16, no
/// magnification) and on the left: Mission Control still shows it, as a thin
/// strip away from the taskbar.
///
/// Never silently: only when `taskbar.hide-dock` is on. Before
/// any change, the user's own values are saved to `~/.local/state/pave/dock.json`;
/// they are written back when the setting is turned off, when Pavé quits, and
/// — if Pavé crashed while the Dock was hidden — at the next launch or with
/// `pave restore-dock`. The Dock is restarted (`killall Dock`, as System
/// Settings does) only when something actually changes.
@MainActor
public final class DockController {
    static let domain = "com.apple.dock"
    static let keys = ["autohide", "autohide-delay", "tilesize", "magnification", "orientation"]
    /// What a state file written before the other keys were managed holds: only these are the user's own.
    static let legacyKeys = ["autohide", "autohide-delay"]
    /// Long enough that the Dock never comes back by itself.
    static let hiddenDelay = 1000.0
    /// The smallest icons the Dock accepts.
    static let hiddenTileSize = 16.0
    static var hiddenValues: [String: CFPropertyList] {
        [
            "autohide": true as CFBoolean, "autohide-delay": hiddenDelay as CFNumber,
            "tilesize": hiddenTileSize as CFNumber, "magnification": false as CFBoolean,
            "orientation": "left" as CFString,
        ]
    }

    public static var stateURL: URL { StateFiles.url("dock.json") }

    /// The Dock is hidden by Pavé (the saved state exists).
    public var isHiddenByPave: Bool { FileManager.default.fileExists(atPath: Self.stateURL.path) }

    public init() {
        // A marker left by a `just dev` with no Pavé to restart is stale.
        RestartMarker.clear()
    }

    /// Brings the Dock in line with what is wanted, restarting it only if needed.
    public func apply(hidden wanted: Bool) {
        if wanted { hide() } else if isHiddenByPave { restore(reason: "setting off") }
        watch(wanted)
    }

    // MARK: - Watch (an app update by the MDM can rewrite the Dock settings)

    private var watchTimer: Timer?
    /// Called once the Dock has been hidden again: the usable area changes,
    /// the taskbar must move back down.
    public var onHiddenAgain: () -> Void = {}
    static let watchInterval: TimeInterval = 5

    /// While Pavé hides the Dock, someone else may rewrite its settings (MDM,
    /// an installer adding its icon, ⌥⌘D) and bring it back: hide it again.
    /// The saved settings are left as they are: they are still the user's own.
    private func watch(_ wanted: Bool) {
        watchTimer?.invalidate()
        watchTimer = nil
        guard wanted else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.check() }
        }
    }

    private func check() {
        guard isHiddenByPave, !rehiding else { return }
        // Re-read from cfprefsd: another process may have written the domain.
        CFPreferencesAppSynchronize(Self.domain as CFString)
        let changed = Self.changedKeys()
        guard !changed.isEmpty else { return }
        Log.info(
            "dock: settings changed outside Pavé (\(changed.map { "\($0)=\(Self.value($0).map { "\($0)" } ?? "none")" }.joined(separator: ", "))), hidden again"
        )
        hide()
        onHiddenAgain()
    }

    private var lastHardRehide = Date.distantPast
    /// Restarting the Dock (`rehideFully`): the watch looks away.
    private var rehiding = false
    /// Automatic full re-hides in a row that left the space reserved.
    private var failedRehides = 0
    private var pendingRetry: DispatchWorkItem?
    static let maxAutomaticRehides = 3

    /// The Dock sometimes stays hidden but still reserves its space (seen
    /// after an MDM rewrite). Pavé ignores that space anyway; this restarts
    /// the Dock, still hidden (never shown), so apps zooming their windows
    /// get it back too. Automatic: at most once a minute, retried when
    /// allowed, 3 times in a row at most (never a loop). `force` ("Reset
    /// Taskbar"): now.
    public func rehideFully(reason: String, force: Bool = false) {
        guard isHiddenByPave, !rehiding else { return }
        if !force {
            guard failedRehides < Self.maxAutomaticRehides else {
                return Log.info(
                    "dock: \(reason), \(failedRehides) restarts already failed, left alone (Reset Taskbar to try again)"
                )
            }
            let wait = 60 - Date().timeIntervalSince(lastHardRehide)
            guard wait <= 0 else {
                guard pendingRetry == nil else { return }
                Log.info("dock: \(reason), restart in \(Int(wait.rounded(.up))) s")
                let retry = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.pendingRetry = nil
                        self?.onHiddenAgain()  // the taskbar looks at the reserve again
                    }
                }
                pendingRetry = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: retry)
                return
            }
            failedRehides += 1
        } else {
            failedRehides = 0
        }
        pendingRetry?.cancel()
        pendingRetry = nil
        lastHardRehide = Date()
        rehiding = true
        Log.info("dock: \(reason), restarting it hidden")
        for (key, value) in Self.hiddenValues { set(key, value) }
        restartDock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.rehiding = false
                self.onHiddenAgain()
            }
        }
    }

    /// The taskbar found no reserve left: automatic re-hides may start again.
    public func reserveIsFine() {
        failedRehides = 0
        pendingRetry?.cancel()
        pendingRetry = nil
    }

    private static func value(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    /// The keys whose value is not the hidden one.
    private static func changedKeys() -> [String] {
        keys.filter { key in
            guard let wanted = hiddenValues[key], let now = value(key) else { return true }
            return !CFEqual(wanted, now)
        }
    }

    /// The saved state: the user's values, and which keys they cover.
    private static func readState() -> (saved: [String: Any], keys: [String])? {
        guard let data = FileManager.default.contents(atPath: stateURL.path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let saved = json["saved"] as? [String: Any]
        else { return nil }
        return (saved, json["keys"] as? [String] ?? legacyKeys)
    }

    private static func writeState(saved: [String: Any], keys: [String]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["saved": saved, "keys": keys, "note": "Dock settings before Pavé hid it"],
            options: [.prettyPrinted, .sortedKeys])
        try StateFiles.write(data, to: stateURL)
    }

    private func hide() {
        // Save first: nothing is changed if the user's values cannot be kept.
        // A state from an older Pavé lacks the newer keys: they are still the
        // user's own (never touched), save them now.
        let state = Self.readState()
        let missing = Self.keys.filter { !(state?.keys.contains($0) ?? false) }
        if !missing.isEmpty {
            var saved = state?.saved ?? [:]
            for key in missing { if let value = Self.value(key) { saved[key] = value } }
            do {
                try Self.writeState(saved: saved, keys: Self.keys)
            } catch {
                return Log.info("dock: NOT hidden, cannot save its settings (\(error.localizedDescription))")
            }
            Log.info(
                "dock: settings saved (\(missing.map { "\($0)=\(saved[$0].map { "\($0)" } ?? "none")" }.joined(separator: ", ")))"
            )
        }
        let changed = Self.changedKeys()
        guard !changed.isEmpty else { return }  // already hidden
        for key in changed { set(key, Self.hiddenValues[key]) }
        restartDock()
        Log.info(
            "dock: hidden (autohide, delay \(Int(Self.hiddenDelay)) s, icons \(Int(Self.hiddenTileSize)) pt, on the left)"
        )
    }

    /// Puts the user's values back and forgets the saved state.
    public func restore(reason: String) {
        watch(false)
        guard let (saved, keys) = Self.readState() else { return }
        for key in keys {
            // A key the user never had is removed, not set to a default.
            set(key, saved[key].map { $0 as CFPropertyList })
        }
        restartDock(wait: true)
        try? FileManager.default.removeItem(at: Self.stateURL)
        Log.info("dock: settings restored (\(reason))")
    }

    /// At quit: restore, unless this is a restart (`just dev`/`just deploy`).
    public func quitting() {
        if RestartMarker.isSet {
            RestartMarker.clear()
            if isHiddenByPave { Log.info("dock: kept hidden across a restart") }
            return
        }
        restore(reason: "Pavé quit")
    }

    private func set(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)
    }

    /// `killall Dock` (macOS restarts it with the new settings), off the main
    /// thread; `wait`: done before returning (at quit, before Pavé exits).
    private func restartDock(wait: Bool = false) {
        guard !wait else {
            _ = try? Shell.run("/usr/bin/killall", ["Dock"])
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { _ = try? Shell.run("/usr/bin/killall", ["Dock"]) }
    }
}
