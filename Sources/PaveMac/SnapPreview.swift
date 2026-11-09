import AppKit
import PaveCore

/// The translucent zone shown while a window is dragged to an edge. Never
/// takes focus nor the mouse; placed just below the dragged
/// window when macOS allows it, like Windows' snap preview.
@MainActor
final class SnapPreview {
    private let panel: NSPanel
    private var shown: Rect?

    init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.borderWidth = 2
        panel.contentView = view
        updateColors()
    }

    private func updateColors() {
        let accent = NSColor.controlAccentColor
        panel.contentView?.layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor
        panel.contentView?.layer?.borderColor = accent.withAlphaComponent(0.75).cgColor
    }

    /// `frame` in AX coordinates; `below`: the dragged window.
    func show(_ frame: Rect, below window: WindowID) {
        guard frame != shown else { return }
        let inset = Rect(x: frame.x + 6, y: frame.y + 6, width: frame.width - 12, height: frame.height - 12)
        let target = Screens.appKit(inset)
        if shown == nil {
            updateColors()
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
            panel.order(.below, relativeTo: Int(window.rawValue))
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                panel.animator().setFrame(target, display: true)
            }
        }
        shown = frame
    }

    func hide() {
        guard shown != nil else { return }
        shown = nil
        panel.orderOut(nil)
    }
}
