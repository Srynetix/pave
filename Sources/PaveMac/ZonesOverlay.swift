import AppKit
import PaveCore

/// The zones of one screen, shown while a window is dragged onto it:
/// every zone with its number, the target ones lit. Never takes focus nor the
/// mouse; placed just below the dragged window, like the snap preview.
@MainActor
final class ZonesOverlay {
    private let panel: NSPanel
    private let view = ZonesView()
    private var screenArea: Rect?

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
        panel.contentView = view
    }

    /// `area`: the screen's usable area; `frames`: the zones, in AX coordinates.
    func show(area: Rect, frames: [Rect], lit: Set<Int>, below window: WindowID) {
        let local = frames.map { Rect(x: $0.x - area.x, y: $0.y - area.y, width: $0.width, height: $0.height) }
        if view.frames != local || view.lit != lit {
            view.frames = local
            view.lit = lit
            view.needsDisplay = true
        }
        guard area != screenArea else { return }
        screenArea = area
        panel.setFrame(Screens.appKit(area), display: true)
        panel.order(.below, relativeTo: Int(window.rawValue))
    }

    func hide() {
        guard screenArea != nil else { return }
        screenArea = nil
        panel.orderOut(nil)
    }
}

/// After ⌃← / ⌃→ into a zone: a small picture of the screen's layout,
/// the target lit, that fades out by itself. Never takes focus nor the mouse.
@MainActor
final class ZonesHUD {
    private let panel: NSPanel
    private let view = ZonesView(fontSize: 15, radius: 5, lineWidth: 1.5)
    private var generation = 0

    static let width: Double = 240
    static let padding: Double = 12
    static let visibleFor: TimeInterval = 0.9

    init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.addSubview(view)
        panel.contentView = background
    }

    /// `area`: the screen's usable area (AX coordinates).
    func show(_ area: Rect, _ zones: ScreenZones, lit: [Int]) {
        let width = Self.width
        let height = (width * area.height / max(area.width, 1)).rounded()
        let miniature = Rect(x: 0, y: 0, width: width, height: height)
        view.frames = zones.layout.frames(in: miniature, gaps: zones.gaps > 0 ? 4 : 0)
        view.lit = Set(lit)
        view.needsDisplay = true
        let p = Self.padding
        view.frame = NSRect(x: p, y: p, width: width, height: height)
        // Centered, in the lower third of the screen.
        let frame = Rect(
            x: (area.x + (area.width - width) / 2 - p).rounded(),
            y: (area.y + area.height * 0.7 - height / 2).rounded(),
            width: width + 2 * p, height: height + 2 * p)
        panel.setFrame(Screens.appKit(frame), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        generation += 1
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                NSAnimationContext.runAnimationGroup({
                    $0.duration = 0.25
                    self.panel.animator().alphaValue = 0
                }) {
                    MainActor.assumeIsolated { if self.generation == shown { self.panel.orderOut(nil) } }
                }
            }
        }
    }
}

private final class ZonesView: NSView {
    var frames: [Rect] = []
    var lit: Set<Int> = []
    private let fontSize: Double, radius: Double, lineWidth: Double

    init(fontSize: Double = 56, radius: Double = 12, lineWidth: Double = 2) {
        self.fontSize = fontSize
        self.radius = radius
        self.lineWidth = lineWidth
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // AX order: top-left origin

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        for (i, f) in frames.enumerated() {
            let rect = NSRect(x: f.x, y: f.y, width: f.width, height: f.height).insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            let on = lit.contains(i)
            (on ? accent.withAlphaComponent(0.45) : NSColor.black.withAlphaComponent(0.22)).setFill()
            path.fill()
            (on ? NSColor.white : NSColor.white.withAlphaComponent(0.55)).setStroke()
            path.lineWidth = lineWidth
            path.stroke()
            // Zone number, centered; hidden on spans' inner zones would be noisier than helpful.
            let text = NSAttributedString(
                string: "\(i + 1)",
                attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(on ? 0.95 : 0.7)])
            let size = text.size()
            guard rect.width > size.width + 4, rect.height > size.height + 4 else { continue }
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }
}
