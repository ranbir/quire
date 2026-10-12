// Renders the Quire app icon: a large gold "24" (a quire is 24 sheets of
// paper) on a black macOS-style tile.
//
//   swift tools/make-icon.swift iconset <output.iconset> [style]
//   swift tools/make-icon.swift preview <output.png>      (all styles side by side)
//
// Styles: serif (default), didot, sans, mono
import AppKit
import CoreText

enum Style: String, CaseIterable {
    case serif, didot, sans, mono

    func font(size: CGFloat) -> CTFont {
        switch self {
        case .serif:
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            let desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return (NSFont(descriptor: desc, size: size) ?? base) as CTFont
        case .didot:
            return (NSFont(name: "Didot-Bold", size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)) as CTFont
        case .sans:
            return NSFont.systemFont(ofSize: size, weight: .black) as CTFont
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .bold) as CTFont
        }
    }

    var label: String {
        switch self {
        case .serif: return "Serif (New York)"
        case .didot: return "Didot"
        case .sans: return "Sans (SF Pro Black)"
        case .mono: return "Mono (SF Mono)"
        }
    }
}

func cg(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Draws the icon into `ctx` filling a `size`×`size` square.
func drawIcon(_ ctx: CGContext, size s: CGFloat, style: Style) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // macOS icon grid: the tile occupies ~80% of the canvas, with room for a shadow.
    let inset = s * 0.098
    let tile = CGRect(x: inset, y: inset * 1.15, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow under the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: cg(0, 0, 0, 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(cg(10, 10, 10))
    ctx.fillPath()
    ctx.restoreGState()

    // Black tile with a faint top-down sheen
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [cg(38, 38, 40), cg(14, 14, 15), cg(4, 4, 4)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    // Hairline gold rim
    ctx.saveGState()
    let rimInset = s * 0.004
    let rim = CGPath(roundedRect: tile.insetBy(dx: rimInset, dy: rimInset), cornerWidth: radius - rimInset, cornerHeight: radius - rimInset, transform: nil)
    ctx.addPath(rim)
    ctx.setStrokeColor(cg(212, 175, 95, s >= 64 ? 0.35 : 0.0))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    // "24" as glyph outlines, scaled to fill the tile optically
    let font = style.font(size: 100)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "24", attributes: [.font: font]))
    let glyphPath = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var positions = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for i in 0..<n {
            if let p = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                glyphPath.addPath(p, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
    }
    let bounds = glyphPath.boundingBoxOfPath
    // Small sizes get relatively larger numerals so they stay legible.
    let fill: CGFloat = s <= 32 ? 0.80 : 0.66
    let scale = min(tile.width * fill / bounds.width, tile.height * 0.56 / bounds.height)
    var t = CGAffineTransform(translationX: tile.midX, y: tile.midY - tile.height * 0.01)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -bounds.midX, y: -bounds.midY)
    let numerals = glyphPath.copy(using: &t)!

    // Soft shadow beneath the numerals
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02, color: cg(0, 0, 0, 0.7))
    ctx.addPath(numerals)
    ctx.setFillColor(cg(120, 85, 25))
    ctx.fillPath()
    ctx.restoreGState()

    // Metallic gold: vertical gradient clipped to the numerals
    ctx.saveGState()
    ctx.addPath(numerals)
    ctx.clip()
    let nb = numerals.boundingBoxOfPath
    let gold = CGGradient(colorsSpace: space,
                          colors: [cg(255, 236, 170), cg(240, 200, 105), cg(205, 155, 55), cg(160, 112, 30), cg(214, 170, 80)] as CFArray,
                          locations: [0, 0.3, 0.55, 0.8, 1])!
    ctx.drawLinearGradient(gold, start: CGPoint(x: 0, y: nb.maxY), end: CGPoint(x: 0, y: nb.minY), options: [])
    ctx.restoreGState()
}

func render(size: Int, style: Style) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    g.cgContext.interpolationQuality = .high
    drawIcon(g.cgContext, size: CGFloat(size), style: style)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make-icon.swift iconset <out.iconset> [style] | preview <out.png>"); exit(1)
}
let out = URL(fileURLWithPath: args[2])

if args[1] == "preview" {
    // One row per style: 512, 128, 64, 32, 16 on a mid-gray card.
    let sizes = [512, 128, 64, 32, 16]
    let rowH = 560, width = 512 + 128 + 64 + 32 + 16 + 6 * 40 + 300
    let total = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: rowH * Style.allCases.count, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: total)
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: rowH * Style.allCases.count).fill()
    for (row, style) in Style.allCases.enumerated() {
        let y = CGFloat(rowH * (Style.allCases.count - 1 - row))
        (style.label as NSString).draw(at: NSPoint(x: 40, y: y + 20),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .medium), .foregroundColor: NSColor.darkGray])
        var x: CGFloat = 40
        for s in sizes {
            let img = NSImage(size: NSSize(width: s, height: s))
            img.addRepresentation(render(size: s, style: style))
            img.draw(in: NSRect(x: x, y: y + 30 + CGFloat(512 - s) / 2 + 10, width: CGFloat(s), height: CGFloat(s)))
            x += CGFloat(s) + 40
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try png(total).write(to: out)
} else {
    let style = args.count > 3 ? Style(rawValue: args[3]) ?? .serif : .serif
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        try png(render(size: size, style: style)).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
        try png(render(size: size * 2, style: style)).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
}
