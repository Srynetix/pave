/// Windows that slide under the taskbar. macOS has no "app bar" API: native
/// zoom and apps that maximize themselves go down to the screen edge once the
/// Dock is hidden. Pavé gives them back the usable area.
public enum TaskbarOverlap {
    /// The frame a window should have so it stops covering the bar, or nil if
    /// it does not cover it (or cannot be fixed sensibly).
    /// - `usable`: the screen's area above the bar (AX coordinates);
    /// - a window whose top is already in the bar, or that would be shorter
    ///   than `minHeight`, is moved up instead of shrunk.
    public static func fix(_ frame: Rect, usable: Rect, minHeight: Double = 120) -> Rect? {
        let barTop = usable.maxY
        guard frame.maxY > barTop + 1 else { return nil }  // above the bar
        // Only windows on this screen horizontally.
        guard min(frame.maxX, usable.maxX) - max(frame.x, usable.x) > 0 else { return nil }
        if frame.y < barTop - minHeight {
            // Taller than what is left: shrink to stop at the bar.
            return Rect(x: frame.x, y: frame.y, width: frame.width, height: barTop - frame.y)
        }
        // Mostly in the bar: move it up, shrinking only if taller than the area.
        let height = min(frame.height, usable.height)
        return Rect(x: frame.x, y: barTop - height, width: frame.width, height: height)
    }
}
