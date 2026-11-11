// Draws Pavé's app icon with AppKit, no image editor needed.
//
//   swift scripts/make-icon.swift <variant> <out.png> [size]
//   just icon   # Resources/AppIcon.icns from the "cobbles" variant (the one in use)
//
// Variants: cobbles (the one in use), tiles, taskbar, snap (earlier ones). The icon follows the macOS grid: an 824 pt
// rounded square centred on a 1024 pt canvas, with a soft drop shadow.
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift cobbles|tiles|taskbar|snap OUT.png [SIZE]\n".utf8))
    exit(2)
}
let variant = args[1]
let out = args[2]
let size = args.count > 3 ? Int(args[3]) ?? 1024 : 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

/// A pave: a rounded rectangle filled with a vertical gradient, with a thin highlight line.
func pave(_ r: NSRect, radius: CGFloat, top: NSColor, bottom: NSColor, shadow: Bool = true) {
    NSGraphicsContext.saveGraphicsState()
    if shadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.28)
        s.shadowBlurRadius = 18
        s.shadowOffset = NSSize(width: 0, height: -8)
        s.set()
    }
    let path = rounded(r, radius)
    top.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: top, ending: bottom)!.draw(in: rounded(r, radius), angle: -90)
    color(0xFFFFFF, 0.55).setStroke()
    let edge = rounded(r.insetBy(dx: 1.5, dy: 1.5), radius - 1.5)
    edge.lineWidth = 3
    edge.stroke()
}

/// Same speckles at every size: a tiny deterministic generator.
struct Seeded {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
}

/// A cobblestone: a slightly irregular, rounded block, bevelled (lit from the
/// top left), speckled like granite. `tilt` in degrees.
func cobble(
    _ r: NSRect, tilt: CGFloat, radius: CGFloat, top: NSColor, bottom: NSColor, seed: UInt64, speckles: Bool = true
) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: r.midX, yBy: r.midY)
    t.rotate(byDegrees: tilt)
    t.translateX(by: -r.midX, yBy: -r.midY)
    t.concat()
    let path = rounded(r, radius)
    // Its shadow in the joint.
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(0.45)
    s.shadowBlurRadius = 22
    s.shadowOffset = NSSize(width: 6, height: -12)
    s.set()
    bottom.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: top, ending: bottom)!.draw(in: r, angle: -70)
    if speckles {
        var rng = Seeded(state: seed)
        for _ in 0..<Int(r.width * r.height / 900) {
            let x = r.minX + rng.next() * r.width
            let y = r.minY + rng.next() * r.height
            let d = 3 + rng.next() * 7
            (rng.next() > 0.5 ? color(0xFFFFFF, 0.10 + 0.08 * rng.next()) : color(0x000000, 0.06 + 0.06 * rng.next()))
                .setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
        }
    }
    // Domed: a soft light towards the top left.
    NSGradient(starting: color(0xFFFFFF, 0.28), ending: color(0xFFFFFF, 0))!
        .draw(
            fromCenter: NSPoint(x: r.minX + r.width * 0.32, y: r.maxY - r.height * 0.25), radius: 0,
            toCenter: NSPoint(x: r.minX + r.width * 0.32, y: r.maxY - r.height * 0.25),
            radius: max(r.width, r.height) * 0.75,
            options: [])
    // Bevel, as inner shadows of the same shape moved aside: light along the
    // top and left edges, dark along the bottom and right ones, no seam.
    for (dx, dy, c) in [(10.0, -10.0, color(0xFFFFFF, 0.45)), (-12.0, 12.0, color(0x000000, 0.30))] {
        let moved = rounded(r.offsetBy(dx: dx, dy: dy), radius)
        let ring = NSBezierPath(rect: r.insetBy(dx: -60, dy: -60))
        ring.append(moved)
        ring.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        let blur = NSShadow()
        blur.shadowColor = c
        blur.shadowBlurRadius = 10
        blur.shadowOffset = .zero
        blur.set()
        c.setFill()
        ring.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
}

func draw(in ctx: CGContext) {
    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 185

    // Drop shadow of the whole icon.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x000000).setFill()
    rounded(body, radius).fill()
    NSGraphicsContext.restoreGraphicsState()

    let clip = rounded(body, radius)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()

    switch variant {
    case "cobbles":
        // Joints: deep slate, a little blue at the top.
        NSGradient(colors: [color(0x334155), color(0x1E293B), color(0x0F172A)])!.draw(in: body, angle: -90)
        let inner = body.insetBy(dx: 96, dy: 96)
        let gap: CGFloat = 40
        let leftW = ((inner.width - gap) * 0.54).rounded()
        let left = NSRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
        let rightX = left.maxX + gap
        let rightW = inner.maxX - rightX
        let h = ((inner.height - gap) / 2).rounded()
        let topRight = NSRect(x: rightX, y: inner.maxY - h, width: rightW, height: h)
        let bottomRight = NSRect(x: rightX, y: inner.minY, width: rightW, height: h - 6)
        // Two granite cobbles, and the lit one: the window in front.
        cobble(topRight, tilt: 1.6, radius: 58, top: color(0xE7E5E4), bottom: color(0xA8A29E), seed: 7)
        cobble(bottomRight, tilt: -1.2, radius: 62, top: color(0xD6D3D1), bottom: color(0x8F8A85), seed: 11)
        cobble(left, tilt: -0.8, radius: 70, top: color(0x7DD3FC), bottom: color(0x1D4ED8), seed: 3)
        // Its title bar dots, tilted with it.
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: left.midX, yBy: left.midY)
        t.rotate(byDegrees: -0.8)
        t.translateX(by: -left.midX, yBy: -left.midY)
        t.concat()
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            color(UInt32(c)).setFill()
            NSBezierPath(ovalIn: NSRect(x: left.minX + 48 + CGFloat(i) * 46, y: left.maxY - 78, width: 28, height: 28))
                .fill()
        }
        color(0xFFFFFF, 0.22).setFill()
        NSBezierPath(rect: NSRect(x: left.minX + 14, y: left.maxY - 112, width: left.width - 28, height: 3)).fill()
        NSGraphicsContext.restoreGraphicsState()
    case "tiles":
        // Deep blue to violet, three glass panes: one tall, two stacked (a tiled workspace).
        NSGradient(colors: [color(0x3B82F6), color(0x4F46E5), color(0x7C3AED)])!.draw(in: body, angle: -60)
        let m: CGFloat = 150
        let gap: CGFloat = 36
        let inner = body.insetBy(dx: m - 100 + 40, dy: m - 100 + 40)
        let leftW = (inner.width - gap) * 0.52
        let left = NSRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
        let rightX = left.maxX + gap
        let rightW = inner.maxX - rightX
        let h = (inner.height - gap) / 2
        let topRight = NSRect(x: rightX, y: inner.minY + h + gap, width: rightW, height: h)
        let bottomRight = NSRect(x: rightX, y: inner.minY, width: rightW, height: h)
        pave(left, radius: 48, top: color(0xFFFFFF), bottom: color(0xE6ECFF))
        pave(topRight, radius: 48, top: color(0xFFFFFF, 0.9), bottom: color(0xDCE4FF, 0.85))
        pave(bottomRight, radius: 48, top: color(0xFFFFFF, 0.7), bottom: color(0xC7D2FE, 0.7))
        // Title-bar dots on the tall pave.
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            color(UInt32(c)).setFill()
            NSBezierPath(ovalIn: NSRect(x: left.minX + 34 + CGFloat(i) * 40, y: left.maxY - 58, width: 24, height: 24))
                .fill()
        }
    case "taskbar":
        // Dusk gradient, two overlapping windows, a taskbar along the bottom.
        NSGradient(colors: [color(0x0EA5E9), color(0x2563EB), color(0x1E1B4B)])!.draw(in: body, angle: -90)
        let back = NSRect(x: 215, y: 380, width: 440, height: 360)
        let front = NSRect(x: 370, y: 300, width: 440, height: 360)
        for (r, alpha) in [(back, 0.75), (front, 1.0)] {
            pave(r, radius: 34, top: color(0xFFFFFF, alpha), bottom: color(0xE0E7FF, alpha))
            color(0x1E3A8A, 0.18 * alpha).setFill()
            NSBezierPath(rect: NSRect(x: r.minX, y: r.maxY - 62, width: r.width, height: 2)).fill()
            for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                color(UInt32(c), alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.minX + 28 + CGFloat(i) * 34, y: r.maxY - 44, width: 20, height: 20))
                    .fill()
            }
        }
        // Taskbar.
        let bar = NSRect(x: body.minX, y: body.minY, width: body.width, height: 150)
        color(0x0B1026, 0.72).setFill()
        NSBezierPath(rect: bar).fill()
        color(0xFFFFFF, 0.12).setFill()
        NSBezierPath(rect: NSRect(x: bar.minX, y: bar.maxY - 2, width: bar.width, height: 2)).fill()
        let icons: [UInt32] = [0x60A5FA, 0xF472B6, 0x34D399, 0xFBBF24]
        for (i, c) in icons.enumerated() {
            let x = 250 + CGFloat(i) * 140
            pave(
                NSRect(x: x, y: bar.minY + 38, width: 84, height: 84), radius: 22, top: color(c), bottom: color(c, 0.8),
                shadow: false)
            if i == 1 {
                color(0xFFFFFF, 0.9).setFill()
                rounded(NSRect(x: x + 22, y: bar.minY + 16, width: 40, height: 8), 4).fill()
            }
        }
    default:  // "snap"
        // Warm-to-cool gradient, a window frame split in two, the left half lit (snapped).
        NSGradient(colors: [color(0xF97316), color(0xDB2777), color(0x7C3AED)])!.draw(in: body, angle: -45)
        let frame = NSRect(x: 230, y: 250, width: 564, height: 524)
        pave(frame, radius: 56, top: color(0xFFFFFF, 0.28), bottom: color(0xFFFFFF, 0.18))
        let half = NSRect(
            x: frame.minX + 26, y: frame.minY + 26, width: (frame.width - 78) / 2, height: frame.height - 52)
        pave(half, radius: 36, top: color(0xFFFFFF), bottom: color(0xFFE4F1))
        let other = NSRect(x: half.maxX + 26, y: half.minY, width: half.width, height: half.height)
        color(0xFFFFFF, 0.55).setStroke()
        let dash = rounded(other, 36)
        dash.lineWidth = 8
        dash.setLineDash([26, 18], count: 2, phase: 0)
        dash.stroke()
    }

    // Glass sheen on the top half.
    NSGradient(starting: color(0xFFFFFF, 0.22), ending: color(0xFFFFFF, 0))!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Thin inner border.
    color(0xFFFFFF, 0.25).setStroke()
    let border = rounded(body.insetBy(dx: 2, dy: 2), radius - 2)
    border.lineWidth = 4
    border.stroke()
    _ = canvas
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
context.imageInterpolation = .high
draw(in: context.cgContext)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
