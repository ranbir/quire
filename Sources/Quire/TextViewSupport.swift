import AppKit
import QuireCore

/// Draws invisibles and the "⋯" capsules that stand in for folded text.
final class InvisiblesLayoutManager: NSLayoutManager {
    var showInvisibles = false
    weak var foldManager: FoldManager?

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let font = (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? Prefs.font
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
    }

    private func invalidate(_ r: NSRange) {
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
        guard !folded.isEmpty, let storage = layoutManager.textStorage else { return 0 }
        let ns = storage.string as NSString
        var modified: [NSLayoutManager.GlyphProperty]?
        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            guard let f = fold(containing: ci) else { continue }
            if modified == nil { modified = Array(UnsafeBufferPointer(start: props, count: glyphRange.length)) }
            let isNewline = ci < ns.length && ns.character(at: ci) == 10
            modified![i] = (ci == f.location || isNewline) ? .controlCharacter : .null
        }
        guard let modified else { return 0 }
        modified.withUnsafeBufferPointer { buf in
            layoutManager.setGlyphs(glyphs, properties: buf.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let f = fold(containing: charIndex) else { return action }
        return charIndex == f.location ? .whitespace : .zeroAdvancement
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let f = fold(containing: charIndex), charIndex == f.location else {
            return NSRect(x: glyphPosition.x, y: 0, width: 0, height: proposedRect.height)
        }
        return NSRect(x: glyphPosition.x, y: 0, width: capsuleWidth, height: proposedRect.height)
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
        NSFont.monospacedDigitSystemFont(ofSize: max(9, (textView?.font?.pointSize ?? 13) - 2), weight: .regular)
    }

    /// Visible lines with their rects in ruler coordinates.
    private func visibleLines() -> [(line: Int, rect: NSRect)] {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return [] }
        let ns = tv.string as NSString
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let inset = tv.textContainerOrigin.y
        var result: [(Int, NSRect)] = []

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
                if !frag.isEmpty { result.append((line, rect(frag))) }
                else if ns.length == 0, let font = tv.font {
                    result.append((line, rect(NSRect(x: 0, y: 0, width: 1, height: lm.defaultLineHeight(for: font)))))
                }
                break
            }
            if foldManager?.isLineHidden(lineStart: start) == true { line += 1; continue }
            let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
            result.append((line, rect(frag)))
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
        for (line, r) in visibleLines() where r.maxY >= rect.minY && r.minY <= rect.maxY {
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
            label.draw(at: NSPoint(x: numberRight - size.width, y: r.minY + (r.height - size.height) / 2), withAttributes: attrs)
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

    func scheduleHighlight() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.highlightNow() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    func highlightNow() {
        guard let tv = textView else { return }
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
