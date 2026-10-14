// Draws the app icon (captain's cap with binoculars on a sea background) into an .iconset folder.
// Usage: swift make-icon.swift <out.iconset> [preview.png]
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func withShadow(_ blur: CGFloat, _ y: CGFloat, _ alpha: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// Everything is drawn on a 1024 × 1024 grid and scaled.
func drawIcon() {
    // Background: rounded square with a sea gradient
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bg = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    withShadow(24, -10, 0.35) {
        rgb(20, 40, 80).setFill()
        bg.fill()
    }
    NSGradient(colors: [rgb(14, 30, 66), rgb(28, 78, 140), rgb(64, 150, 200)])!.draw(in: bg, angle: 90)

    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    // Soft light behind the cap
    NSGradient(colors: [rgb(255, 240, 200, 0.35), rgb(255, 240, 200, 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 680), radius: 0, toCenter: NSPoint(x: 512, y: 680), radius: 420,
              options: [])
    // Waves
    for (i, alpha) in [(0, 0.22), (1, 0.32), (2, 0.5)] {
        let y = 250 - CGFloat(i) * 55
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: 80, y: y))
        var x: CGFloat = 80
        while x < 960 {
            let shift = CGFloat(i) * 40
            wave.curve(to: NSPoint(x: x + 160, y: y), controlPoint1: NSPoint(x: x + 50 + shift / 4, y: y + 34),
                       controlPoint2: NSPoint(x: x + 110 - shift / 4, y: y - 34))
            x += 160
        }
        wave.line(to: NSPoint(x: 960, y: 60))
        wave.line(to: NSPoint(x: 80, y: 60))
        wave.close()
        rgb(120, 200, 235, alpha).setFill()
        wave.fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    drawBinoculars()
    drawCap()
}

func drawCap() {
    // White crown
    let crown = NSBezierPath()
    crown.move(to: NSPoint(x: 300, y: 560))
    crown.curve(to: NSPoint(x: 190, y: 705), controlPoint1: NSPoint(x: 250, y: 600), controlPoint2: NSPoint(x: 175, y: 660))
    crown.curve(to: NSPoint(x: 512, y: 812), controlPoint1: NSPoint(x: 205, y: 780), controlPoint2: NSPoint(x: 370, y: 815))
    crown.curve(to: NSPoint(x: 834, y: 705), controlPoint1: NSPoint(x: 654, y: 815), controlPoint2: NSPoint(x: 819, y: 780))
    crown.curve(to: NSPoint(x: 724, y: 560), controlPoint1: NSPoint(x: 849, y: 660), controlPoint2: NSPoint(x: 774, y: 600))
    crown.close()
    withShadow(30, -14, 0.4) {
        NSColor.white.setFill()
        crown.fill()
    }
    NSGradient(colors: [rgb(205, 214, 228), rgb(250, 251, 253), .white])!.draw(in: crown, angle: 90)
    // Seam across the crown
    let seam = NSBezierPath()
    seam.move(to: NSPoint(x: 215, y: 690))
    seam.curve(to: NSPoint(x: 809, y: 690), controlPoint1: NSPoint(x: 380, y: 735), controlPoint2: NSPoint(x: 644, y: 735))
    seam.lineWidth = 6
    rgb(190, 200, 215).setStroke()
    seam.stroke()

    // Black band
    let band = NSBezierPath(roundedRect: NSRect(x: 292, y: 500, width: 440, height: 78), xRadius: 14, yRadius: 14)
    NSGradient(colors: [rgb(10, 14, 28), rgb(36, 44, 70)])!.draw(in: band, angle: 90)

    // Visor
    let visor = NSBezierPath()
    visor.move(to: NSPoint(x: 268, y: 512))
    visor.curve(to: NSPoint(x: 756, y: 512), controlPoint1: NSPoint(x: 350, y: 392), controlPoint2: NSPoint(x: 674, y: 392))
    visor.curve(to: NSPoint(x: 268, y: 512), controlPoint1: NSPoint(x: 674, y: 478), controlPoint2: NSPoint(x: 350, y: 478))
    visor.close()
    withShadow(18, -10, 0.45) {
        rgb(8, 10, 18).setFill()
        visor.fill()
    }
    NSGradient(colors: [rgb(6, 8, 14), rgb(48, 56, 78)])!.draw(in: visor, angle: 90)
    // Visor highlight
    let shine = NSBezierPath()
    shine.move(to: NSPoint(x: 340, y: 480))
    shine.curve(to: NSPoint(x: 684, y: 480), controlPoint1: NSPoint(x: 420, y: 440), controlPoint2: NSPoint(x: 604, y: 440))
    shine.lineWidth = 7
    shine.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.25).setStroke()
    shine.stroke()

    // Gold cord on the band
    let gold = NSGradient(colors: [rgb(176, 120, 30), rgb(250, 210, 90), rgb(196, 140, 40)])!
    let cord = NSBezierPath(roundedRect: NSRect(x: 300, y: 508, width: 424, height: 22), xRadius: 11, yRadius: 11)
    gold.draw(in: cord, angle: 90)
    NSGraphicsContext.saveGraphicsState()
    cord.addClip()
    rgb(140, 90, 20, 0.7).setStroke()
    var x: CGFloat = 290
    while x < 740 {
        let twist = NSBezierPath()
        twist.move(to: NSPoint(x: x, y: 506))
        twist.line(to: NSPoint(x: x + 16, y: 532))
        twist.lineWidth = 4
        twist.stroke()
        x += 18
    }
    NSGraphicsContext.restoreGraphicsState()
    // Cord buttons
    for bx in [312.0, 712.0] {
        let button = NSBezierPath(ovalIn: NSRect(x: bx - 16, y: 503, width: 32, height: 32))
        gold.draw(in: button, relativeCenterPosition: NSPoint(x: -0.3, y: 0.4))
    }

    drawBadge(gold)
}

func drawBadge(_ gold: NSGradient) {
    // Laurel leaves
    for side in [-1.0, 1.0] {
        for i in 0..<5 {
            let t = CGFloat(i)
            let cx = 512 + side * (58 + t * 6)
            let cy = 560 + t * 24
            let leaf = NSBezierPath(ovalIn: NSRect(x: -11, y: -22, width: 22, height: 44))
            var transform = AffineTransform(translationByX: cx, byY: cy)
            transform.rotate(byDegrees: side * (-28 - t * 8))
            leaf.transform(using: transform)
            gold.draw(in: leaf, angle: 90)
        }
    }

    // Anchor
    let anchor = NSBezierPath()
    anchor.lineWidth = 16
    anchor.lineCapStyle = .round
    anchor.move(to: NSPoint(x: 512, y: 655))
    anchor.line(to: NSPoint(x: 512, y: 545))
    anchor.move(to: NSPoint(x: 476, y: 625))
    anchor.line(to: NSPoint(x: 548, y: 625))
    anchor.move(to: NSPoint(x: 458, y: 580))
    anchor.curve(to: NSPoint(x: 566, y: 580), controlPoint1: NSPoint(x: 470, y: 530), controlPoint2: NSPoint(x: 554, y: 530))
    let ring = NSBezierPath(ovalIn: NSRect(x: 497, y: 652, width: 30, height: 30))
    ring.lineWidth = 10
    withShadow(4, -2, 0.35) {
        rgb(232, 180, 60).setStroke()
        anchor.stroke()
        ring.stroke()
    }
    rgb(255, 228, 130).setStroke()
    let highlight = NSBezierPath()
    highlight.lineWidth = 5
    highlight.lineCapStyle = .round
    highlight.move(to: NSPoint(x: 508, y: 645))
    highlight.line(to: NSPoint(x: 508, y: 560))
    highlight.stroke()
    // Flukes
    for (px, dir) in [(458.0, -1.0), (566.0, 1.0)] {
        let fluke = NSBezierPath()
        fluke.move(to: NSPoint(x: px + dir * 14, y: 600))
        fluke.line(to: NSPoint(x: px - dir * 6, y: 572))
        fluke.line(to: NSPoint(x: px + dir * 18, y: 568))
        fluke.close()
        rgb(232, 180, 60).setFill()
        fluke.fill()
    }
}

func drawBinoculars() {
    let metal = NSGradient(colors: [rgb(18, 20, 28), rgb(58, 64, 80), rgb(24, 26, 34)])!
    withShadow(28, -16, 0.5) {
        // Bridge
        let bridge = NSBezierPath(roundedRect: NSRect(x: 450, y: 300, width: 124, height: 70), xRadius: 18, yRadius: 18)
        rgb(30, 32, 42).setFill()
        bridge.fill()
        for cx in [392.0, 632.0] {
            let barrel = NSBezierPath(roundedRect: NSRect(x: cx - 100, y: 170, width: 200, height: 250), xRadius: 60, yRadius: 60)
            rgb(30, 32, 42).setFill()
            barrel.fill()
        }
    }
    let bridge = NSBezierPath(roundedRect: NSRect(x: 450, y: 300, width: 124, height: 70), xRadius: 18, yRadius: 18)
    metal.draw(in: bridge, angle: 0)
    // Focus wheel
    let wheel = NSBezierPath(roundedRect: NSRect(x: 482, y: 360, width: 60, height: 42), xRadius: 10, yRadius: 10)
    NSGradient(colors: [rgb(150, 156, 170), rgb(220, 224, 232), rgb(120, 126, 140)])!.draw(in: wheel, angle: 0)
    rgb(90, 96, 110).setStroke()
    for i in 0..<6 {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 488 + CGFloat(i) * 10, y: 364))
        line.line(to: NSPoint(x: 488 + CGFloat(i) * 10, y: 398))
        line.lineWidth = 3
        line.stroke()
    }

    for cx in [392.0, 632.0] {
        let barrel = NSBezierPath(roundedRect: NSRect(x: cx - 100, y: 170, width: 200, height: 250), xRadius: 60, yRadius: 60)
        metal.draw(in: barrel, angle: 0)
        // Lens: metal ring, glass, reflections
        let ringRect = NSRect(x: cx - 84, y: 196, width: 168, height: 168)
        NSGradient(colors: [rgb(210, 214, 224), rgb(110, 116, 130), rgb(230, 232, 238)])!
            .draw(in: NSBezierPath(ovalIn: ringRect), angle: -45)
        let glass = NSBezierPath(ovalIn: ringRect.insetBy(dx: 16, dy: 16))
        NSGradient(colors: [rgb(10, 40, 90), rgb(40, 140, 200), rgb(120, 230, 240)])!
            .draw(in: glass, relativeCenterPosition: NSPoint(x: 0.3, y: -0.3))
        NSGradient(colors: [rgb(90, 200, 255, 0.35), rgb(90, 200, 255, 0)])!
            .draw(in: NSBezierPath(ovalIn: ringRect.insetBy(dx: 30, dy: 30)), relativeCenterPosition: NSPoint(x: -0.4, y: 0.4))
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - 42, y: 296, width: 34, height: 22)).fill()
        NSColor.white.withAlphaComponent(0.4).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx + 18, y: 232, width: 16, height: 12)).fill()
    }
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(px) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try! render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
