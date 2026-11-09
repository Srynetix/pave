import Foundation

/// macOS's own window tiling (Sequoia and later): dragging to an edge, or
/// with ⌥ held. It fights with Pavé's drag snap, and
/// its ⌥ shortcut collides with "⌥ = drag without snapping".
///
/// Pavé never changes it on its own: it shows the state in the
/// menu and switches it only when the user asks. Both settings live in
/// `com.apple.WindowManager`, the domain System Settings writes.
public enum NativeTiling {
    static var domain: CFString { "com.apple.WindowManager" as CFString }
    static let keys = ["EnableTilingByEdgeDrag", "EnableTilingOptionAccelerator"]

    /// Settings currently on (missing = on: macOS's default).
    public static func enabledSettings() -> [String] {
        CFPreferencesAppSynchronize(domain)
        return keys.filter { key in
            (CFPreferencesCopyAppValue(key as CFString, domain) as? Bool) ?? true
        }
    }

    public static var isEnabled: Bool { !enabledSettings().isEmpty }

    /// Turns both settings on or off. Returns false if the write failed.
    @discardableResult
    public static func set(enabled: Bool) -> Bool {
        for key in keys {
            CFPreferencesSetAppValue(key as CFString, enabled as CFBoolean, domain)
        }
        let ok = CFPreferencesAppSynchronize(domain)
        Log.info("native tiling \(enabled ? "enabled" : "disabled") from Pavé's menu (\(ok ? "saved" : "SAVE FAILED"))")
        return ok
    }

    /// Stage Manager (same domain): it groups and moves windows on its own,
    /// which tiling and parking cannot live with. Pavé
    /// only warns, like for native tiling.
    public static var stageManagerEnabled: Bool {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain) as? Bool) ?? false
    }
}
