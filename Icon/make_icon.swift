// Renders the Folder Drill app icon to Resources/AppIcon.icns.
// Usage (from the repo root):  swift Icon/make_icon.swift
//
// Design: a navy macOS-style rounded square holding a two-level "sunburst"
// usage chart. The inner ring is a folder's contents; the outer arc breaks the
// biggest slice down one more level (the drill-down). A chevron in the middle
// points down.

import AppKit

let canvas: CGFloat = 1024
let center = CGPoint(x: canvas / 2, y: canvas / 2)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Ring segment from fraction `f0` to `f1` (0 = 12 o'clock, clockwise).
func segment(_ f0: CGFloat, _ f1: CGFloat, inner: CGFloat, outer: CGFloat, gapDeg: CGFloat) -> NSBezierPath {
    let a0 = 90 - f0 * 360 - gapDeg / 2
    let a1 = 90 - f1 * 360 + gapDeg / 2
    let p = NSBezierPath()
    p.appendArc(withCenter: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: true)
    p.appendArc(withCenter: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: false)
    p.close()
    return p
}

func render(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)   // draw in 1024-pt space at any pixel size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Body: Apple's icon grid puts an 824pt rounded square on the 1024 canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    color(0x1A2240).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x33437A), color(0x1B2347), color(0x10152B)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: bodyPath, angle: -90)

    // Soft glow behind the chart.
    NSGradient(colors: [color(0x6FA8FF, 0.22), color(0x6FA8FF, 0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 360, options: [])

    // Inner ring: one folder's children.
    let slices: [(CGFloat, UInt32)] = [
        (0.40, 0x35D0BA), // teal (the big one we drill into)
        (0.21, 0x4F8DFF), // blue
        (0.14, 0x9B6BFF), // violet
        (0.10, 0xFF5FA2), // pink
        (0.08, 0xFF9F43), // orange
        (0.07, 0xFFD43B), // yellow
    ]
    var f: CGFloat = 0
    for (frac, hex) in slices {
        let path = segment(f, f + frac, inner: 150, outer: 285, gapDeg: 2.2)
        NSGradient(colors: [color(hex), color(hex).blended(withFraction: 0.25, of: .black)!])!
            .draw(in: path, relativeCenterPosition: .zero)
        f += frac
    }

    // Outer arc: the big slice, drilled into one level deeper.
    let sub: [(CGFloat, CGFloat)] = [(0.45, 0.95), (0.25, 0.8), (0.18, 0.65), (0.12, 0.5)]
    f = 0
    for (part, alpha) in sub {
        let span = 0.40 * part
        color(0x7FF0DE, alpha).setFill()
        segment(f, f + span, inner: 300, outer: 352, gapDeg: 2.2).fill()
        f += span
    }

    // Center chevron pointing down.
    let chevron = NSBezierPath()
    chevron.move(to: CGPoint(x: center.x - 62, y: center.y + 30))
    chevron.line(to: CGPoint(x: center.x, y: center.y - 32))
    chevron.line(to: CGPoint(x: center.x + 62, y: center.y + 30))
    chevron.lineWidth = 34
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor.white.setStroke()
    chevron.stroke()

    // Top sheen.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(size: 1024).write(to: root.appendingPathComponent("Icon/AppIcon.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
try! fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
