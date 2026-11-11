// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit

/// The menu bar icon, matching the app icon: three cobbles laid as a zone
/// layout, the tall one lit (filled, its title bar cut out), the two others
/// outlined. A template image drawn in code: macOS tints it for light, dark
/// and highlighted menu bars, and it stays sharp at any scale.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 16)

    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pavé"
        return image
    }

    static func draw() {
        NSColor.black.set()
        let line: CGFloat = 1.1

        // The lit cobble: filled, a title bar line cut out near its top.
        let tall = NSRect(x: 0.75, y: 0.75, width: 8.5, height: 14.5)
        NSBezierPath(roundedRect: tall, xRadius: 2.4, yRadius: 2.4).fill()
        clear(NSRect(x: tall.minX + 1.6, y: tall.maxY - 3.6, width: tall.width - 3.2, height: 1.0), radius: 0.5)

        // The two others: outlined, one above the other.
        for rect in [
            NSRect(x: 11.1, y: 8.6, width: 6.2, height: 6.6), NSRect(x: 11.1, y: 0.8, width: 6.2, height: 6.4),
        ] {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: line / 2, dy: line / 2), xRadius: 1.9, yRadius: 1.9)
            path.lineWidth = line
            path.stroke()
        }
    }

    /// Erases a rounded area (the template's transparent parts).
    private static func clear(_ rect: NSRect, radius: CGFloat = 0.5) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
