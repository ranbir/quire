import AppKit
import QuireCore

/// Draws invisibles, the "⋯" capsules that stand in for folded text, and backgrounds
/// behind Markdown code blocks.
final class InvisiblesLayoutManager: NSLayoutManager {
    var showInvisibles = false
    weak var foldManager: FoldManager?

    struct MarkdownBlock: Equatable {
        enum Kind { case code, quote }
        var range: NSRange
        var kind: Kind
        /// Quote bars: distance from the text's left edge.
        var indent: CGFloat = 0
        /// Quote bars: a GitHub alert's colour.
        var color: NSColor? = nil
    }
    /// Inline code spans, sorted; drawn as rounded backgrounds that follow the text across lines.
    var inlineCode: [NSRange] = []
    /// Set by MarkdownStyler; drawn full width behind the text.
    var markdownBlocks: [MarkdownBlock] = []
    /// Pictures for Live Preview widgets, by id, and where their baseline is (0 top, 1 bottom).
    var widgetImage: ((Int) -> NSImage?)?
    var widgetBaseline: ((Int) -> CGFloat?)?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if !markdownBlocks.isEmpty, let tc = textContainers.first, let storage = textStorage {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            let width = tc.size.width < 1e6 ? tc.size.width : (tc.textView?.bounds.width ?? 0)
            for block in markdownBlocks where NSIntersectionRange(block.range, chars).length > 0 && NSMaxRange(block.range) <= storage.length {
                let glyphs = glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                let first = drawnLineFragment(from: block.range.location)
                let last = blockEndFragment(block.range, glyphs: glyphs)
                let rect = NSRect(x: first.minX + tc.lineFragmentPadding - 4, y: first.minY - 2,
                              width: width - tc.lineFragmentPadding * 2 + 8, height: last.maxY - first.minY + 4)
                switch block.kind {
                case .code:
                    Theme.markdownCodeBackground.setFill()
                    NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 5, yRadius: 5).fill()
                case .quote:
                    (block.color ?? Theme.markdownQuoteBar).setFill()
                    NSRect(x: first.minX + tc.lineFragmentPadding + block.indent + origin.x, y: first.minY + origin.y + 1,
                           width: 3, height: last.maxY - first.minY - 2).fill()
                }
            }
        }
        drawInlineCode(in: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// A rounded background per line piece of each code span: unlike a background colour
    /// attribute, it doesn't spill into the indent when the span wraps.
    private func drawInlineCode(in glyphsToShow: NSRange, at origin: NSPoint) {
        guard !inlineCode.isEmpty, let tc = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var lo = 0, hi = inlineCode.count
        while lo < hi { let mid = (lo + hi) / 2; if NSMaxRange(inlineCode[mid]) <= chars.location { lo = mid + 1 } else { hi = mid } }
        Theme.markdownCodeBackground.setFill()
        var i = lo
        while i < inlineCode.count, inlineCode[i].location < NSMaxRange(chars) {
            let glyphs = glyphRange(forCharacterRange: inlineCode[i], actualCharacterRange: nil)
            let ns = (textStorage?.string ?? "") as NSString
            enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                var piece = self.characterRange(forGlyphRange: NSIntersectionRange(lineGlyphs, glyphs), actualGlyphRange: nil)
                // Not the spaces where the line wraps.
                while piece.length > 0, [32, 10].contains(ns.character(at: NSMaxRange(piece) - 1)) { piece.length -= 1 }
                while piece.length > 0, ns.character(at: piece.location) == 32 { piece.location += 1; piece.length -= 1 }
                guard piece.length > 0 else { return }
                let rect = self.boundingRect(forGlyphRange: self.glyphRange(forCharacterRange: piece, actualCharacterRange: nil), in: tc)
                guard rect.width > 0.5 else { return }
                let r = rect.insetBy(dx: -2, dy: 1).offsetBy(dx: origin.x, dy: origin.y)
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            }
            i += 1
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let font = Prefs.font
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        if showInvisibles {
            let ns = storage.string as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.invisibles]
            for i in chars.location..<NSMaxRange(chars) {
                let symbol: String
                switch ns.character(at: i) {
                case 9: symbol = "‣"
                case 10: symbol = "¬"
                case 32: symbol = "·"
                default: continue
                }
                if foldManager?.isHidden(i) == true { continue }
                let g = glyphIndexForCharacter(at: i)
                let fragment = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let loc = location(forGlyphAt: g)
                (symbol as NSString).draw(at: NSPoint(x: origin.x + fragment.minX + loc.x, y: origin.y + fragment.minY), withAttributes: attrs)
            }
        }

        drawMarkdownWidgets(in: chars, at: origin)

        guard let folds = foldManager?.folded, !folds.isEmpty else { return }
        for f in folds where NSLocationInRange(f.location, chars) {
            let r = capsuleRect(for: f).offsetBy(dx: origin.x, dy: origin.y)
            Theme.foldCapsule.setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2.5, yRadius: r.height / 2.5).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.foldCapsuleText]
            let s = "⋯" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
    }

    /// The line fragment of the first character from `i` that is drawn: hidden Live Preview
    /// markup lays out as null glyphs, which report the previous line's fragment.
    func drawnLineFragment(from i: Int) -> NSRect {
        guard let storage = textStorage, storage.length > 0 else { return .zero }
        let ns = storage.string as NSString
        var c = min(i, ns.length - 1)
        while c < ns.length - 1, let m = foldManager?.markup(at: c), ns.character(at: c) != 10 { c = NSMaxRange(m.range) }
        return lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: min(c, ns.length - 1)), effectiveRange: nil)
    }

    /// The last line fragment of a block: the one holding the line break after it.
    private func blockEndFragment(_ r: NSRange, glyphs: NSRange) -> NSRect {
        guard let storage = textStorage else { return .zero }
        if NSMaxRange(r) < storage.length {
            return lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: NSMaxRange(r)), effectiveRange: nil)
        }
        return lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
    }

    /// The baseline (from the top of the line fragment) of ordinary text next to `range` on
    /// the same line; control glyphs don't report it reliably.
    private func textBaseline(near range: NSRange, glyph g: Int, fallback: CGFloat) -> CGFloat {
        var lineGlyphs = NSRange()
        _ = lineFragmentRect(forGlyphAt: g, effectiveRange: &lineGlyphs)
        for candidate in [glyphIndexForCharacter(at: NSMaxRange(range)), glyphIndexForCharacter(at: max(range.location, 1) - 1)] where NSLocationInRange(candidate, lineGlyphs) {
            if propertyForGlyph(at: candidate) == [] { return location(forGlyphAt: candidate).y }
        }
        return fallback
    }

    /// Checkbox for a Live Preview task marker, in text-container coordinates.
    func checkboxRect(for m: FoldManager.Markup) -> NSRect {
        guard let fm = foldManager else { return .zero }
        let g = glyphIndexForCharacter(at: m.range.location)
        let line = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let loc = location(forGlyphAt: g)
        let size = min(fm.checkboxWidth - 6, Prefs.font.pointSize + 1)
        let baseline = line.minY + loc.y
        // Centred on the middle of capital letters.
        return NSRect(x: line.minX + loc.x + 1, y: baseline - Prefs.font.capHeight / 2 - size / 2, width: size, height: size).integral
    }

    private func drawMarkdownWidgets(in chars: NSRange, at origin: NSPoint) {
        guard let fm = foldManager, !fm.markup.isEmpty, let tc = textContainers.first else { return }
        for m in fm.markup where NSIntersectionRange(m.range, chars).length > 0 {
            switch m.style {
            case .checkbox(let checked):
                let r = checkboxRect(for: m).offsetBy(dx: origin.x, dy: origin.y)
                let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                if checked {
                    NSColor.controlAccentColor.setFill()
                    box.fill()
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: r.minX + r.width * 0.25, y: r.midY))
                    tick.line(to: NSPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.72))
                    tick.line(to: NSPoint(x: r.minX + r.width * 0.77, y: r.minY + r.height * 0.3))
                    tick.lineWidth = 1.6
                    tick.lineCapStyle = .round
                    tick.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    tick.stroke()
                } else {
                    Theme.markdownMuted.setStroke()
                    box.lineWidth = 1
                    box.stroke()
                }
            case .rule:
                let g = glyphIndexForCharacter(at: m.range.location)
                let line = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let width = tc.size.width < 1e6 ? tc.size.width : (tc.textView?.bounds.width ?? 0)
                Theme.markdownQuoteBar.setFill()
                NSRect(x: line.minX + tc.lineFragmentPadding + origin.x, y: (line.midY).rounded() + origin.y,
                       width: width - tc.lineFragmentPadding * 2, height: 1).fill()
            case .widget(let id, let size, let block):
                guard let image = widgetImage?(id) else { continue }
                let g = glyphIndexForCharacter(at: m.anchor)
                let line = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let loc = location(forGlyphAt: g)
                var x = line.minX + loc.x
                if block {
                    let width = tc.size.width < 1e6 ? tc.size.width : (tc.textView?.bounds.width ?? size.width)
                    x = line.minX + max(tc.lineFragmentPadding, (width - size.width) / 2)
                }
                // Inline pictures sit on the text's baseline, with about a fifth of them below it like descenders.
                // Math knows where its baseline is; images sit on the baseline.
                let ratio = widgetBaseline?(id) ?? 1
                let y = block ? line.minY + (line.height - size.height) / 2 : line.minY + textBaseline(near: m.range, glyph: g, fallback: loc.y) - size.height * ratio
                image.draw(in: NSRect(x: x + origin.x, y: y + origin.y, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            case .hidden, .bullet:
                break
            }
        }
    }

    /// Capsule rect in text-container coordinates.
    func capsuleRect(for fold: NSRange) -> NSRect {
        guard let tc = textContainers.first else { return .zero }
        let g = glyphIndexForCharacter(at: fold.location)
        var r = boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        let line = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        r.origin.y = line.minY + 2
        r.size.height = max(8, line.height - 4)
        return r.insetBy(dx: 1, dy: 0)
    }
}

/// Hides folded text at the glyph level: folded characters generate null
/// glyphs, and line breaks inside a fold stop breaking lines. The first
/// folded character becomes a fixed-width box where the capsule is drawn.
final class FoldManager: NSObject, NSLayoutManagerDelegate {
    weak var layoutManager: NSLayoutManager?
    var onChange: (() -> Void)?
    var capsuleWidth: CGFloat = 24

    /// Hidden ranges, sorted and non-overlapping.
    private(set) var folded: [NSRange] = []

    /// Folds the scanner found in the current text.
    var available: [FoldRange] = [] { didSet { availableByLine = FoldScanner.foldsByLine(available) } }
    private(set) var availableByLine: [Int: FoldRange] = [:]

    func fold(containing i: Int) -> NSRange? {
        var lo = 0, hi = folded.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let f = folded[mid]
            if i < f.location { hi = mid - 1 }
            else if i >= NSMaxRange(f) { lo = mid + 1 }
            else { return f }
        }
        return nil
    }

    func isHidden(_ i: Int) -> Bool { fold(containing: i) != nil }

    // MARK: Markdown Live Preview

    /// How Live Preview shows a piece of Markdown markup away from the cursor.
    enum MarkupStyle: Equatable {
        /// Not drawn and takes no space.
        case hidden
        /// A list marker drawn as "•".
        case bullet
        /// A task marker drawn as a checkbox.
        case checkbox(checked: Bool)
        /// A thematic break drawn as a line across the text.
        case rule
        /// A picture (image, math, diagram) drawn in place of the text. `block` widgets
        /// collapse their lines into one and are centred.
        case widget(id: Int, size: NSSize, block: Bool)
    }

    struct Markup: Equatable {
        var range: NSRange
        var style: MarkupStyle

        /// The character a widget is laid out and drawn at: its last one. Glyphs before it are
        /// hidden, and hidden glyphs at the start of a line are laid out with the line before,
        /// so anchoring on the first character would put the picture on the wrong line.
        var anchor: Int {
            if case .widget = style { return NSMaxRange(range) - 1 }
            return range.location
        }
    }

    /// Markup Live Preview hides or replaces, sorted by location.
    private(set) var markup: [Markup] = []
    var checkboxWidth: CGFloat = 20

    func markup(at i: Int) -> Markup? {
        var lo = 0, hi = markup.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let m = markup[mid]
            if i < m.range.location { hi = mid - 1 }
            else if i >= NSMaxRange(m.range) { lo = mid + 1 }
            else { return m }
        }
        return nil
    }

    /// Replaces the markup list and re-lays out `changed`.
    func setMarkup(_ new: [Markup], changed: [NSRange]) {
        markup = new
        for r in changed where r.length > 0 { invalidate(r) }
    }

    /// True when a line starting at `lineStart` is entirely covered by a fold.
    func isLineHidden(lineStart: Int) -> Bool {
        guard lineStart > 0, let f = fold(containing: lineStart - 1) else { return false }
        return lineStart > f.location
    }

    func isFolded(_ r: NSRange) -> Bool { folded.contains(r) }

    func fold(_ r: NSRange) {
        guard r.length > 0 else { return }
        if folded.contains(where: { NSLocationInRange(r.location, $0) && NSMaxRange(r) <= NSMaxRange($0) }) { return }
        var changed = r
        folded.removeAll { f in
            let overlaps = NSIntersectionRange(f, r).length > 0
            if overlaps { changed = NSUnionRange(changed, f) }
            return overlaps
        }
        folded.append(r)
        folded.sort { $0.location < $1.location }
        invalidate(changed)
    }

    func unfold(_ r: NSRange) {
        guard let i = folded.firstIndex(of: r) else { return }
        folded.remove(at: i)
        invalidate(r)
    }

    /// Unfolds every fold intersecting `r` (or containing its location, for an empty range).
    @discardableResult
    func unfold(intersecting r: NSRange) -> Bool {
        let hits = folded.filter { f in
            r.length == 0 ? (r.location > f.location && r.location < NSMaxRange(f)) : NSIntersectionRange(f, r).length > 0
        }
        hits.forEach(unfold)
        return !hits.isEmpty
    }

    func unfoldAll() {
        let all = folded
        folded.removeAll()
        all.forEach(invalidate)
    }

    func reset() {
        folded.removeAll()
        available = []
    }

    /// Keeps folds in place across edits; folds touched by an edit open up.
    func textEdited(range edited: NSRange, delta: Int) {
        let oldEnd = edited.location + edited.length - delta
        var opened: [NSRange] = []
        folded = folded.compactMap { f in
            if NSMaxRange(f) <= edited.location { return f }                                  // edit after the fold
            if f.location >= oldEnd { return NSRange(location: f.location + delta, length: f.length) }   // edit before it
            opened.append(NSRange(location: f.location, length: max(0, f.length + delta)))
            return nil
        }
        if !opened.isEmpty {
            DispatchQueue.main.async { [weak self] in opened.forEach { self?.invalidate($0) } }
        }
        // Live Preview markup moves with the text until the next parse replaces it.
        if !markup.isEmpty {
            markup = markup.compactMap { m in
                if NSMaxRange(m.range) <= edited.location { return m }
                if m.range.location >= oldEnd { return Markup(range: NSRange(location: m.range.location + delta, length: m.range.length), style: m.style) }
                return nil
            }
        }
    }

    func invalidate(_ r: NSRange) {
        guard let lm = layoutManager, let len = lm.textStorage?.length else { return }
        let start = min(r.location, len)
        let range = NSRange(location: start, length: min(len, NSMaxRange(r) + 1) - start)
        lm.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        onChange?()
    }

    // MARK: NSLayoutManagerDelegate

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !folded.isEmpty || !markup.isEmpty, let storage = layoutManager.textStorage else { return 0 }
        let ns = storage.string as NSString
        var modified: [NSLayoutManager.GlyphProperty]?
        var newGlyphs: [CGGlyph]?
        func mutate() {
            if modified == nil { modified = Array(UnsafeBufferPointer(start: props, count: glyphRange.length)) }
        }
        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            if let f = fold(containing: ci) {
                mutate()
                let isNewline = ci < ns.length && ns.character(at: ci) == 10
                modified![i] = (ci == f.location || isNewline) ? .controlCharacter : .null
                continue
            }
            guard let m = markup(at: ci) else { continue }
            switch m.style {
            case .hidden:
                mutate()
                modified![i] = .null
            case .bullet:
                if newGlyphs == nil { newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length)) }
                var bullet = CGGlyph(0)
                var ch: UniChar = 0x2022
                if CTFontGetGlyphsForCharacters(aFont as CTFont, &ch, &bullet, 1) { newGlyphs![i] = bullet }
            case .checkbox, .rule:
                mutate()
                modified![i] = ci == m.range.location ? .controlCharacter : .null
            case .widget:
                mutate()
                let isNewline = ci < ns.length && ns.character(at: ci) == 10
                modified![i] = ci == m.anchor || isNewline ? .controlCharacter : .null
            }
        }
        guard modified != nil || newGlyphs != nil else { return 0 }
        let finalProps = modified ?? Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        let finalGlyphs = newGlyphs ?? Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        finalProps.withUnsafeBufferPointer { p in
            finalGlyphs.withUnsafeBufferPointer { g in
                layoutManager.setGlyphs(g.baseAddress!, properties: p.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            }
        }
        return glyphRange.length
    }

    /// True when the text line that `chars` belongs to is nothing but hidden markup. A line
    /// fragment belongs to the line whose line break it holds: hidden markup at the start of
    /// a line can be laid out in the previous line's fragment, so its own characters don't say.
    func isAllHidden(_ chars: NSRange, in ns: NSString) -> Bool {
        guard chars.length > 0 else { return false }
        var end = chars.location
        while end < NSMaxRange(chars), ns.character(at: end) != 10 { end += 1 }
        if end == NSMaxRange(chars) && end < ns.length { return false }   // a wrapped part of a longer line
        var start = end
        while start > 0, ns.character(at: start - 1) != 10 { start -= 1 }
        guard end > start else { return false }   // an empty line
        var p = start
        while p < end {
            guard let m = markup(at: p), m.style == .hidden else { return false }
            p = NSMaxRange(m.range)
        }
        return true
    }

    /// True when the text line of `chars` lies inside a picture but isn't the line the picture
    /// is drawn on (each source line still gets a line fragment; those collapse).
    func isInsideWidget(_ chars: NSRange, in ns: NSString) -> Bool {
        guard chars.length > 0 else { return false }
        var end = chars.location
        while end < NSMaxRange(chars), ns.character(at: end) != 10 { end += 1 }
        var start = end
        while start > 0, ns.character(at: start - 1) != 10 { start -= 1 }
        guard let m = markup(at: start), case .widget = m.style, end <= NSMaxRange(m.range) || (end < ns.length && NSLocationInRange(end, m.range)) else { return false }
        return !(m.anchor >= start && m.anchor <= end)
    }

    /// Lines holding widgets grow to fit them; the text's baseline moves down with them.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard !markup.isEmpty, let storage = layoutManager.textStorage else { return false }
        let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        if isAllHidden(chars, in: storage.string as NSString) || isInsideWidget(chars, in: storage.string as NSString) {
            // A line of nothing but hidden markup (a code fence, a setext underline) shrinks to a sliver.
            let h = max(2, (lineFragmentRect.pointee.height * 0.3).rounded())
            lineFragmentRect.pointee.size.height = h
            lineFragmentUsedRect.pointee.size.height = h
            baselineOffset.pointee = h
            return true
        }
        var lo = 0, hi = markup.count
        while lo < hi { let mid = (lo + hi) / 2; if NSMaxRange(markup[mid].range) <= chars.location { lo = mid + 1 } else { hi = mid } }
        var needed: CGFloat = 0
        var i = lo
        while i < markup.count, markup[i].range.location < NSMaxRange(chars) {
            if case .widget(_, let size, _) = markup[i].style, NSLocationInRange(markup[i].anchor, chars) {
                needed = max(needed, size.height + 6)
            }
            i += 1
        }
        let rect = lineFragmentRect.pointee
        guard needed > rect.height else { return false }
        let extra = needed - rect.height
        lineFragmentRect.pointee.size.height += extra
        lineFragmentUsedRect.pointee.size.height += extra
        baselineOffset.pointee += extra - 3
        return true
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if let f = fold(containing: charIndex) { return charIndex == f.location ? .whitespace : .zeroAdvancement }
        if let m = markup(at: charIndex) {
            guard charIndex == m.anchor else { return .zeroAdvancement }   // line breaks inside a widget
            switch m.style {
            case .checkbox, .widget: return .whitespace
            default: return .zeroAdvancement
            }
        }
        return action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        if let f = fold(containing: charIndex), charIndex == f.location {
            return NSRect(x: glyphPosition.x, y: 0, width: capsuleWidth, height: proposedRect.height)
        }
        if let m = markup(at: charIndex), charIndex == m.anchor {
            switch m.style {
            case .checkbox:
                return NSRect(x: glyphPosition.x, y: 0, width: checkboxWidth, height: proposedRect.height)
            case .widget(_, let size, let block):
                let width = block ? max(size.width, proposedRect.width - glyphPosition.x - 4) : size.width
                return NSRect(x: glyphPosition.x, y: 0, width: min(width, max(proposedRect.width - glyphPosition.x - 4, 1)), height: proposedRect.height)
            default: break
            }
        }
        return NSRect(x: glyphPosition.x, y: 0, width: 0, height: proposedRect.height)
    }
}

/// Gutter: Git change bars, line numbers and fold disclosure triangles.
final class LineNumberRulerView: NSRulerView {
    weak var textView: EditorTextView?
    weak var foldManager: FoldManager?
    var lineIndex = LineIndex("")
    var gitMarkers: [Int: ChangeMarker] = [:] { didSet { needsDisplay = true } }

    static let markerWidth: CGFloat = 4
    static let foldColumnWidth: CGFloat = 14

    init(textView: EditorTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 56
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func textDidChange() {
        guard let tv = textView else { return }
        lineIndex = LineIndex(tv.string)
        let digits = max(3, String(lineIndex.lineCount).count)
        let w = ceil(("8" as NSString).size(withAttributes: [.font: labelFont]).width * CGFloat(digits))
            + 10 + Self.markerWidth + Self.foldColumnWidth
        if abs(w - ruleThickness) > 0.5 { ruleThickness = w }
        needsDisplay = true
    }

    var labelFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(9, Prefs.font.pointSize - 2), weight: .regular)
    }

    /// Visible lines with their rects in ruler coordinates.
    /// Visible lines: the first line fragment's rect and, when the line starts with ordinary
    /// text, its baseline (both in ruler coordinates).
    private func visibleLines() -> [(line: Int, rect: NSRect, baseline: CGFloat?)] {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return [] }
        let ns = tv.string as NSString
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let inset = tv.textContainerOrigin.y
        var result: [(Int, NSRect, CGFloat?)] = []

        func rect(_ frag: NSRect) -> NSRect {
            let y = convert(NSPoint(x: 0, y: frag.minY + inset), from: tv).y
            return NSRect(x: 0, y: y, width: ruleThickness, height: frag.height)
        }

        var line = lineIndex.line(for: chars.location)
        while line < lineIndex.lineCount {
            let start = lineIndex.starts[line]
            if start > NSMaxRange(chars) { break }
            if start >= ns.length {
                // Empty last line after a trailing newline (or an empty document).
                let frag = lm.extraLineFragmentRect
                if !frag.isEmpty { result.append((line, rect(frag), nil)) }
                else if ns.length == 0, let font = tv.font {
                    result.append((line, rect(NSRect(x: 0, y: 0, width: 1, height: lm.defaultLineHeight(for: font))), nil))
                }
                break
            }
            if foldManager?.isLineHidden(lineStart: start) == true { line += 1; continue }
            // Lines of nothing but hidden markup are collapsed; leave them unnumbered.
            if let fm = foldManager, !fm.markup.isEmpty {
                let lineRange = ns.lineRange(for: NSRange(location: start, length: 0))
                if fm.isAllHidden(lineRange, in: ns) { line += 1; continue }
            }
            // Lines folded into a block widget share its line; only the first is numbered.
            if let m = foldManager?.markup(at: start), case .widget = m.style, start > m.range.location { line += 1; continue }
            // Hidden Live Preview markup lays out as null glyphs, which report the previous
            // line's fragment: measure from the first character that is drawn.
            var first = start
            while first < ns.length, let m = foldManager?.markup(at: first), ns.character(at: first) != 10 { first = NSMaxRange(m.range) }
            let g = lm.glyphIndexForCharacter(at: min(first, max(ns.length - 1, 0)))
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            var baseline: CGFloat?
            let startsWithWidget: Bool = {
                if let m = foldManager?.markup(at: start), case .widget(_, _, true) = m.style { return true }
                return false
            }()
            if !startsWithWidget, first < ns.length, ns.character(at: first) != 10, lm.propertyForGlyph(at: g) == [] {
                baseline = convert(NSPoint(x: 0, y: frag.minY + lm.location(forGlyphAt: g).y + inset), from: tv).y
            }
            result.append((line, rect(frag), baseline))
            line += 1
        }
        return result
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.gutterBackground.setFill()
        bounds.fill()
        Theme.pageGuide.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let tv = textView else { return }

        let caretLine = lineIndex.line(for: tv.selectedRange().location)
        let font = labelFont
        let numberRight = ruleThickness - Self.foldColumnWidth - 2
        for (line, r, baseline) in visibleLines() where r.maxY >= rect.minY && r.minY <= rect.maxY {
            // Git change bar
            if let m = gitMarkers[line] {
                switch m {
                case .added: Theme.gitAdded.setFill(); NSRect(x: 0, y: r.minY, width: Self.markerWidth, height: r.height).fill()
                case .modified: Theme.gitModified.setFill(); NSRect(x: 0, y: r.minY, width: Self.markerWidth, height: r.height).fill()
                case .deletedAbove:
                    Theme.gitDeleted.setFill()
                    let p = NSBezierPath()
                    p.move(to: NSPoint(x: 0, y: r.minY - 4)); p.line(to: NSPoint(x: 7, y: r.minY)); p.line(to: NSPoint(x: 0, y: r.minY + 4))
                    p.fill()
                }
            }
            // Line number
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: line == caretLine ? Theme.gutterCurrent : Theme.gutterText]
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            // On the text's baseline (headings, lines after pictures); centred beside block pictures.
            let y = baseline.map { $0 - font.ascender } ?? r.minY + (r.height - size.height) / 2
            label.draw(at: NSPoint(x: numberRight - size.width, y: y), withAttributes: attrs)
            // Fold triangle
            if let f = foldManager?.availableByLine[line] {
                let folded = foldManager?.isFolded(f.range) == true
                drawTriangle(folded: folded, in: NSRect(x: ruleThickness - Self.foldColumnWidth, y: r.minY, width: Self.foldColumnWidth - 2, height: min(r.height, 18)))
            }
        }
    }

    private func drawTriangle(folded: Bool, in r: NSRect) {
        let s: CGFloat = 7
        let c = NSPoint(x: r.midX, y: r.midY)
        let p = NSBezierPath()
        if folded {
            p.move(to: NSPoint(x: c.x - s / 2.6, y: c.y - s / 2)); p.line(to: NSPoint(x: c.x + s / 2, y: c.y)); p.line(to: NSPoint(x: c.x - s / 2.6, y: c.y + s / 2))
        } else {
            p.move(to: NSPoint(x: c.x - s / 2, y: c.y - s / 2.6)); p.line(to: NSPoint(x: c.x + s / 2, y: c.y - s / 2.6)); p.line(to: NSPoint(x: c.x, y: c.y + s / 2.6))
        }
        p.close()
        (folded ? Theme.gutterCurrent : Theme.gutterText).setFill()
        p.fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let local = convert(event.locationInWindow, from: nil)

        // Fold column toggles the fold on that line.
        if local.x >= ruleThickness - Self.foldColumnWidth - 2, let fm = foldManager,
           let hit = visibleLines().first(where: { $0.rect.minY <= local.y && local.y < $0.rect.maxY }),
           let f = fm.availableByLine[hit.line] {
            if fm.isFolded(f.range) { fm.unfold(f.range) } else { fm.fold(f.range) }
            return
        }

        // Elsewhere: click selects the line; drag extends.
        func charIndex(_ e: NSEvent) -> Int {
            var p = tv.convert(e.locationInWindow, from: nil)
            p.x = 5; p.y -= tv.textContainerOrigin.y
            return lm.characterIndex(for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        }
        let ns = tv.string as NSString
        let anchor = ns.lineRange(for: NSRange(location: min(charIndex(event), ns.length), length: 0))
        tv.setSelectedRange(anchor)
        window?.makeFirstResponder(tv)
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type == .leftMouseDragged {
            tv.autoscroll(with: e)
            let r = ns.lineRange(for: NSRange(location: min(charIndex(e), ns.length), length: 0))
            tv.setSelectedRange(NSUnionRange(anchor, r))
        }
    }
}

/// Applies syntax colours as layout-manager temporary attributes so that
/// highlighting never touches the text storage (and therefore never dirties
/// the document or pollutes undo). Tokenising runs off the main thread.
final class SyntaxHighlighter {
    private weak var textView: NSTextView?
    private var tokenizer: Tokenizer
    private var generation = 0
    private var pending: DispatchWorkItem?
    private static let queue = DispatchQueue(label: "quire.highlight", qos: .userInitiated)
    static let maxLength = 4_000_000

    init(textView: NSTextView, language: Language) {
        self.textView = textView
        self.tokenizer = Tokenizer(language: language)
    }

    func setLanguage(_ language: Language) {
        tokenizer = Tokenizer(language: language)
        highlightNow()
    }

    /// Off while MarkdownStyler formats the document.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { highlightNow() } else { generation += 1; pending?.cancel() }
        }
    }

    func scheduleHighlight() {
        guard isEnabled else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.highlightNow() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    func highlightNow() {
        guard isEnabled, let tv = textView else { return }
        generation += 1
        let gen = generation
        let text = tv.string
        let length = (text as NSString).length
        let tokenizer = self.tokenizer
        guard length <= Self.maxLength else { apply([], length: length); return }
        Self.queue.async { [weak self] in
            let tokens = tokenizer.tokenize(text)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.apply(tokens, length: length)
            }
        }
    }

    private func apply(_ tokens: [Token], length: Int) {
        guard let tv = textView, let lm = tv.layoutManager, (tv.string as NSString).length == length else { return }
        let full = NSRange(location: 0, length: length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        for t in tokens where NSMaxRange(t.range) <= length {
            lm.addTemporaryAttribute(.foregroundColor, value: Theme.color(for: t.kind), forCharacterRange: t.range)
        }
    }
}
