import ApplicationServices

/// TCC permissions the window manager depends on.
public enum Permissions {
    /// Whether the process is trusted for Accessibility.
    /// With `prompt: true`, macOS shows its "grant access" dialog when not trusted.
    @MainActor
    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        // The constant is a global `var` imported from C; read its value instead of
        // referencing it so Swift 6 strict concurrency accepts it.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
