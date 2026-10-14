// Draws the DMG window background (660 × 400 pt) at 1x and 2x.
// Usage: swift make-dmg-background.swift <out-1x.png> <out-2x.png>
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let size = NSSize(width: 660, height: 400)

func draw() {
    let rect = NSRect(origin: .zero, size: size)
    NSGradient(colors: [rgb(214, 232, 246), rgb(246, 250, 253)])!.draw(in: rect, angle: 90)

    // Waves at the bottom
    for (i, alpha) in [(0, 0.25), (1, 0.4)] {
        let y = 70 - CGFloat(i) * 28
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: 0, y: y))
        var x: CGFloat = 0
        while x < size.width {
            wave.curve(to: NSPoint(x: x + 110, y: y), controlPoint1: NSPoint(x: x + 35, y: y + 16),
                       controlPoint2: NSPoint(x: x + 75, y: y - 16))
            x += 110
        }
        wave.line(to: NSPoint(x: size.width, y: 0))
        wave.line(to: NSPoint(x: 0, y: 0))
        wave.close()
        rgb(70, 150, 205, alpha).setFill()
        wave.fill()
    }

    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let title = NSAttributedString(string: "Kommandant", attributes: [
        .font: NSFont.systemFont(ofSize: 30, weight: .bold),
        .foregroundColor: rgb(20, 40, 80),
        .paragraphStyle: center,
    ])
    title.draw(in: NSRect(x: 0, y: 318, width: size.width, height: 40))
    let subtitle = NSAttributedString(string: "Zum Installieren Kommandant auf den Ordner „Programme“ ziehen", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: rgb(60, 80, 110),
        .paragraphStyle: center,
    ])
    subtitle.draw(in: NSRect(x: 0, y: 292, width: size.width, height: 22))

    // Dashed arrow between the two icon positions (icons centered at x 170 and 490, y 200 from the top)
    let y: CGFloat = size.height - 200
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 260, y: y))
    arrow.curve(to: NSPoint(x: 392, y: y), controlPoint1: NSPoint(x: 300, y: y + 30), controlPoint2: NSPoint(x: 352, y: y + 30))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    arrow.setLineDash([2, 14], count: 2, phase: 0)
    rgb(40, 110, 190).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 408, y: y - 4))
    head.line(to: NSPoint(x: 384, y: y + 18))
    head.line(to: NSPoint(x: 382, y: y - 12))
    head.close()
    rgb(40, 110, 190).setFill()
    head.fill()
}

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: CommandLine.arguments[1])
render(scale: 2, to: CommandLine.arguments[2])
