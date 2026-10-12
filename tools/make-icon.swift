// Renders the Quire app icon into an .iconset directory.
// Usage: swift tools/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.33, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.09, blue: 0.16, alpha: 1)])!.draw(in: path, angle: -90)

    // Page
    let page = NSRect(x: s * 0.27, y: s * 0.2, width: s * 0.46, height: s * 0.6)
    NSColor(white: 0.97, alpha: 1).setFill()
    NSBezierPath(roundedRect: page, xRadius: s * 0.03, yRadius: s * 0.03).fill()
    // Code lines
    let colors: [NSColor] = [.systemPink, .systemTeal, .systemOrange, .systemIndigo, .systemTeal, .systemPink]
    let widths: [CGFloat] = [0.30, 0.22, 0.34, 0.18, 0.28, 0.14]
    let indents: [CGFloat] = [0, 0.04, 0.04, 0.08, 0.04, 0]
    for i in 0..<6 {
        let y = page.maxY - s * 0.1 - CGFloat(i) * s * 0.075
        colors[i].withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: page.minX + s * (0.05 + indents[i]), y: y, width: s * widths[i], height: s * 0.032),
                     xRadius: s * 0.016, yRadius: s * 0.016).fill()
    }
    // Quill stroke
    let quill = NSBezierPath()
    quill.move(to: NSPoint(x: s * 0.62, y: s * 0.28))
    quill.curve(to: NSPoint(x: s * 0.86, y: s * 0.84), controlPoint1: NSPoint(x: s * 0.70, y: s * 0.52), controlPoint2: NSPoint(x: s * 0.78, y: s * 0.72))
    quill.curve(to: NSPoint(x: s * 0.62, y: s * 0.28), controlPoint1: NSPoint(x: s * 0.70, y: s * 0.70), controlPoint2: NSPoint(x: s * 0.63, y: s * 0.50))
    NSColor(srgbRed: 1.0, green: 0.78, blue: 0.30, alpha: 1).setFill()
    quill.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
