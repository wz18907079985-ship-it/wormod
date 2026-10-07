import Cocoa

// Usage: swift icon.swift <out.iconset> [preview.png]
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Draws on a 1024-unit canvas, scaled to `px`.
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

    // background squircle
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(starting: rgb(0xFFF4D6), ending: rgb(0xFFDCE6))!.draw(in: squircle, angle: -90)

    // three panes (the workspace)
    let paneLine = rgb(0x3B2F2F, 0.9)
    let panes = [NSRect(x: 215, y: 250, width: 300, height: 520),
                 NSRect(x: 545, y: 525, width: 264, height: 245),
                 NSRect(x: 545, y: 250, width: 264, height: 245)]
    for (i, r) in panes.enumerated() {
        let p = NSBezierPath(roundedRect: r, xRadius: 44, yRadius: 44)
        (i == 0 ? rgb(0xFFFFFF, 0.85) : rgb(0xFFFFFF, 0.6)).setFill()
        p.fill()
        paneLine.setStroke()
        p.lineWidth = 22
        p.stroke()
    }

    // worm body: a chubby wave across the bottom panes
    let wormGreen = rgb(0x8BD96B)
    let wormDark = rgb(0x3B2F2F)
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 250, y: 300))
    path.curve(to: NSPoint(x: 470, y: 330), controlPoint1: NSPoint(x: 300, y: 430), controlPoint2: NSPoint(x: 420, y: 430))
    path.curve(to: NSPoint(x: 640, y: 380), controlPoint1: NSPoint(x: 520, y: 230), controlPoint2: NSPoint(x: 610, y: 240))
    path.lineCapStyle = .round
    path.lineJoinStyle = .round

    path.lineWidth = 170
    wormDark.setStroke(); path.stroke()
    path.lineWidth = 128
    wormGreen.setStroke(); path.stroke()

    // soft highlight along the back
    let shine = NSBezierPath()
    shine.move(to: NSPoint(x: 268, y: 352))
    shine.curve(to: NSPoint(x: 400, y: 392), controlPoint1: NSPoint(x: 300, y: 420), controlPoint2: NSPoint(x: 360, y: 425))
    shine.lineWidth = 26; shine.lineCapStyle = .round
    rgb(0xC4F2A8).setStroke(); shine.stroke()

    // head
    let head = NSRect(x: 560, y: 340, width: 250, height: 230)
    let headPath = NSBezierPath(ovalIn: head.insetBy(dx: -21, dy: -21))
    wormDark.setFill(); headPath.fill()
    wormGreen.setFill(); NSBezierPath(ovalIn: head).fill()

    // antennae
    for (sx, ex) in [(640.0, 610.0), (730.0, 770.0)] as [(CGFloat, CGFloat)] {
        let a = NSBezierPath()
        a.move(to: NSPoint(x: sx, y: 560))
        a.curve(to: NSPoint(x: ex, y: 660), controlPoint1: NSPoint(x: sx, y: 620), controlPoint2: NSPoint(x: ex, y: 610))
        a.lineWidth = 20; a.lineCapStyle = .round; wormDark.setStroke(); a.stroke()
        wormDark.setFill(); NSBezierPath(ovalIn: NSRect(x: ex - 26, y: 645, width: 52, height: 52)).fill()
        rgb(0xFF8FB1).setFill(); NSBezierPath(ovalIn: NSRect(x: ex - 15, y: 656, width: 30, height: 30)).fill()
    }

    // eyes
    for cx in [640.0, 735.0] as [CGFloat] {
        wormDark.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - 30, y: 440, width: 60, height: 72)).fill()
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - 8, y: 482, width: 22, height: 22)).fill()
    }
    // blush
    rgb(0xFF8FB1, 0.75).setFill()
    NSBezierPath(ovalIn: NSRect(x: 578, y: 400, width: 52, height: 30)).fill()
    NSBezierPath(ovalIn: NSRect(x: 748, y: 400, width: 52, height: 30)).fill()
    // smile
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: 668, y: 425))
    smile.curve(to: NSPoint(x: 708, y: 425), controlPoint1: NSPoint(x: 675, y: 395), controlPoint2: NSPoint(x: 701, y: 395))
    smile.lineWidth = 14; smile.lineCapStyle = .round; wormDark.setStroke(); smile.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
if CommandLine.arguments.count > 2 {
    try! render(512).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
