import AppKit
import QuireCore

/// Formats Markdown inside the editor (the Styled and Live Preview modes): heading sizes,
/// bold, italic and code fonts, hanging indents for list items and quotes, dimmed markers,
/// and backgrounds behind code blocks.
///
/// Fonts and paragraph styles are real attributes of the text storage, set outside the
/// text view's editing path, so they never reach the file, the undo stack or the document's
/// edited state. Colours are layout-manager temporary attributes, like syntax colouring.
/// After an edit only the lines whose formatting changed are restyled.
final class MarkdownStyler {
    private weak var textView: EditorTextView?
    private(set) var spans: [MarkdownSpan] = []
    /// Live Preview: markers hidden or drawn as widgets away from the cursor.
    var live = false {
        didSet { if live != oldValue { applied ? restyleAll() : () } }
    }
    /// Block ranges whose markup is currently shown because the selection touches them.
    private var revealed: [NSRange] = []
    /// Pictures for images, math and diagrams in Live Preview.
    let widgets = MarkdownWidgets()
    /// The document's folder, for relative image paths.
    var baseURL: (() -> URL?)?
    /// Ranges whose pictures are still rendering; laid out again when they arrive.
    private var waitingForWidgets: [NSRange] = []
    /// Space left of quoted lines for each level's bar in Live Preview.
    static let quoteIndent: CGFloat = 16
    /// Called after formatting is applied, with the restyled range (Live Preview hooks in here).
    var didApply: ((NSRange) -> Void)?

    /// Main-thread time of the last pass, in seconds (parsing included when it ran on the main thread).
    private(set) var lastPassDuration: TimeInterval = 0
    /// The range restyled by the last pass.
    private(set) var lastRegion = NSRange(location: 0, length: 0)
    private var applied = false
    private var dirty: NSRange?
    private var delta = 0
    private var generation = 0
    private var scheduled = false
    private static let queue = DispatchQueue(label: "quire.markdown-style", qos: .userInitiated)
    /// Larger documents are shown as Source.
    static let maxLength = 4_000_000
    /// Larger documents get Styled formatting instead of Live Preview.
    static let liveMaxLength = 2_000_000
    /// A full pass over more text than this styles the visible part first and the rest in chunks.
    static let chunkLength = 40_000

    init(textView: EditorTextView) {
        self.textView = textView
        widgets.onReady = { [weak self] in
            guard let self, let tv = self.textView, self.live, !self.hasPendingEdits else { return }
            let waiting = self.waitingForWidgets
            self.updateLive(selection: tv.selectedRange(), alsoInvalidate: waiting)
        }
        (textView.layoutManager as? InvisiblesLayoutManager)?.widgetImage = { [weak self] id in self?.widgets.image(id: id) }
        (textView.layoutManager as? InvisiblesLayoutManager)?.widgetBaseline = { [weak self] id in self?.widgets.baseline(id: id) }
    }

    private var storage: NSTextStorage? { textView?.textStorage }
    private var layoutManager: InvisiblesLayoutManager? { textView?.layoutManager as? InvisiblesLayoutManager }

    // MARK: Scheduling

    /// Records an edit (in post-edit coordinates) so the next pass can restyle just around it.
    func noteEdit(range: NSRange, delta change: Int) {
        generation += 1
        if !pendingChunks.isEmpty {
            let oldEnd = NSMaxRange(range) - change
            pendingChunks = pendingChunks.map { r in
                if NSMaxRange(r) <= range.location { return r }
                if r.location >= oldEnd { return NSRange(location: r.location + change, length: r.length) }
                let start = min(r.location, range.location)
                return NSRange(location: start, length: max(NSMaxRange(r) + change, NSMaxRange(range)) - start)
            }
        }
        guard applied else { return }
        guard let d = dirty else { dirty = range; delta = change; return }
        let oldEditEnd = NSMaxRange(range) - change
        let start = min(d.location, range.location)
        let dEnd = NSMaxRange(d) >= oldEditEnd ? NSMaxRange(d) + change : NSMaxRange(d)
        let end = max(dEnd, NSMaxRange(range))
        dirty = NSRange(location: start, length: max(0, end - start))
        delta += change
    }

    /// Re-parses after the text changed (coalesced to one pass per run-loop turn).
    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.parse(full: false)
        }
    }

    /// Formats the whole document from scratch (after loading, a font change or a mode switch).
    func restyleAll() {
        generation += 1
        pendingChunks = []
        applied = false
        dirty = nil
        delta = 0
        parse(full: true)
    }

    /// Removes the decorations and colours; the caller resets fonts and paragraph styles.
    func remove() {
        generation += 1
        applied = false
        dirty = nil
        delta = 0
        spans = []
        revealed = []
        pendingChunks = []
        guard let lm = layoutManager, let storage else { return }
        let all = NSRange(location: 0, length: storage.length)
        for key in Self.temporaryKeys { lm.removeTemporaryAttribute(key, forCharacterRange: all) }
        lm.markdownBlocks = []
        lm.inlineCode = []
        lm.foldManager?.setMarkup([], changed: [all])
        lm.invalidateDisplay(forCharacterRange: all)
    }

    private func parse(full: Bool) {
        guard let tv = textView else { return }
        let text = tv.string
        guard (text as NSString).length <= Self.maxLength else { return }
        let gen = generation
        // Small documents are styled synchronously so typing never shows unstyled text.
        if (text as NSString).length < 60_000 {
            let start = Date()
            apply(MarkdownDocument(text).spans, full: full || !applied)
            lastPassDuration = Date().timeIntervalSince(start)
            return
        }
        Self.queue.async { [weak self] in
            let spans = MarkdownDocument(text).spans
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                let start = Date()
                self.apply(spans, full: full || !self.applied)
                self.lastPassDuration = Date().timeIntervalSince(start)
            }
        }
    }

    // MARK: Applying

    private func apply(_ new: [MarkdownSpan], full: Bool) {
        guard let storage, let textView else { return }
        let length = storage.length
        let ns = storage.string as NSString
        var region = NSRange(location: 0, length: length)
        if !full, let d = dirty {
            region = changedRegion(old: spans, new: new, dirty: d, delta: delta, length: length)
        }
        region = ns.paragraphRange(for: NSRange(location: min(region.location, length), length: min(region.length, length - min(region.location, length))))
        spans = new
        lastRegion = region
        applied = true
        dirty = nil
        delta = 0
        guard region.length > Self.chunkLength else {
            style(region, in: textView, storage: storage)
            updateLive(selection: textView.selectedRange(), alsoInvalidate: full ? [NSRange(location: 0, length: length)] : [region])
            didApply?(region)
            return
        }
        // Big passes: what's on screen first, then the rest a chunk per run-loop turn.
        let visible: NSRange = {
            guard let lm = textView.layoutManager, let tc = textView.textContainer else { return NSRange(location: region.location, length: 0) }
            let glyphs = lm.glyphRange(forBoundingRect: textView.visibleRect, in: tc)
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let lo = max(region.location, chars.location - 4_000), hi = min(NSMaxRange(region), NSMaxRange(chars) + 4_000)
            return ns.paragraphRange(for: NSRange(location: lo, length: max(0, hi - lo)))
        }()
        style(visible, in: textView, storage: storage)
        updateLive(selection: textView.selectedRange(), alsoInvalidate: [visible])
        var rest: [NSRange] = []
        var i = region.location
        while i < NSMaxRange(region) {
            let chunk = ns.paragraphRange(for: NSRange(location: i, length: min(Self.chunkLength, NSMaxRange(region) - i)))
            for part in [NSRange(location: chunk.location, length: max(0, min(NSMaxRange(chunk), visible.location) - chunk.location)),
                         NSRange(location: max(chunk.location, NSMaxRange(visible)), length: max(0, NSMaxRange(chunk) - max(chunk.location, NSMaxRange(visible))))]
            where part.length > 0 { rest.append(part) }
            i = max(NSMaxRange(chunk), i + 1)
        }
        pendingChunks = rest
        runChunks()
    }

    /// Text still to be styled after a big pass, kept in step with edits.
    private var pendingChunks: [NSRange] = []
    private var chunksRunning = false
    /// True while a big document is still being formatted in the background.
    var isStylingInBackground: Bool { !pendingChunks.isEmpty }

    /// Styles one pending chunk per run-loop turn, so typing stays responsive.
    private func runChunks() {
        guard !chunksRunning else { return }
        chunksRunning = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.chunksRunning = false
            guard let storage = self.storage, let tv = self.textView, !self.pendingChunks.isEmpty else { return }
            let part = self.pendingChunks.removeFirst()
            let ns = storage.string as NSString
            let start = min(part.location, ns.length)
            let clamped = NSRange(location: start, length: max(0, min(NSMaxRange(part), ns.length) - start))
            if clamped.length > 0 { self.style(ns.paragraphRange(for: clamped), in: tv, storage: storage) }
            if self.pendingChunks.isEmpty {
                self.updateLive(selection: tv.selectedRange())
            } else {
                self.runChunks()
            }
        }
    }

    /// The part of the text whose formatting differs between the old and new spans. Spans
    /// are in document order, so equal runs at the start (unshifted) and at the end (shifted
    /// by the edit's length change) are skipped and whatever lies between is restyled.
    private func changedRegion(old: [MarkdownSpan], new: [MarkdownSpan], dirty d: NSRange, delta: Int, length: Int) -> NSRange {
        func shifted(_ s: MarkdownSpan) -> MarkdownSpan {
            MarkdownSpan(kind: s.kind, range: NSRange(location: s.range.location + delta, length: s.range.length),
                         block: NSRange(location: s.block.location + delta, length: s.block.length))
        }
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p], NSMaxRange(old[p].block) <= d.location, NSMaxRange(old[p].range) <= d.location { p += 1 }
        let oldDirtyEnd = NSMaxRange(d) - delta
        var q = 0
        while q < old.count - p, q < new.count - p {
            let o = old[old.count - 1 - q]
            guard o.range.location >= oldDirtyEnd, o.block.location >= oldDirtyEnd, shifted(o) == new[new.count - 1 - q] else { break }
            q += 1
        }
        var lo = d.location, hi = NSMaxRange(d)
        for s in new[p..<(new.count - q)] { lo = min(lo, s.range.location); hi = max(hi, NSMaxRange(s.range)) }
        for s in old[p..<(old.count - q)] {
            let r = s.range.location >= oldDirtyEnd ? NSRange(location: s.range.location + delta, length: s.range.length) : s.range
            lo = min(lo, r.location); hi = max(hi, NSMaxRange(r))
        }
        lo = max(0, min(lo, length))
        hi = max(lo, min(hi, length))
        return NSRange(location: lo, length: hi - lo)
    }

    static let temporaryKeys: [NSAttributedString.Key] = [.foregroundColor, .backgroundColor, .strikethroughStyle, .underlineStyle]

    static let headingScale: [CGFloat] = [1.6, 1.4, 1.2, 1.1, 1.0, 1.0]

    private func style(_ region: NSRange, in tv: EditorTextView, storage: NSTextStorage) {
        guard let lm = layoutManager else { return }
        let base = Prefs.font
        let basePara = tv.defaultParagraphStyle ?? .default
        let fm = NSFontManager.shared
        let mono = NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
        let baseIsMono = base.isFixedPitch
        let inRegion = spans.filter { NSIntersectionRange($0.range, region).length > 0 || ($0.range.length == 0 && NSLocationInRange($0.range.location, region)) }

        func fonts(_ r: NSRange, _ transform: (NSFont) -> NSFont) {
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                storage.addAttribute(.font, value: transform((value as? NSFont) ?? base), range: sub)
            }
        }
        func color(_ c: NSColor, _ r: NSRange) { lm.addTemporaryAttribute(.foregroundColor, value: c, forCharacterRange: r) }

        storage.beginEditing()
        storage.addAttributes([.font: base, .paragraphStyle: basePara], range: region)
        for key in Self.temporaryKeys { lm.removeTemporaryAttribute(key, forCharacterRange: region) }

        // Content: fonts and colours (parents come before their children).
        var headingLines: [Int: Int] = [:]   // line start → level
        for s in inRegion {
            let r = NSIntersectionRange(s.range, region)
            guard r.length > 0 else { continue }
            switch s.kind {
            case .heading(let level):
                let scale = Self.headingScale[min(max(level, 1), 6) - 1]
                fonts(r) { fm.convert(fm.convert($0, toSize: base.pointSize * scale), toHaveTrait: .boldFontMask) }
                headingLines[(storage.string as NSString).lineRange(for: NSRange(location: s.range.location, length: 0)).location] = level
            case .strong:
                fonts(r) { fm.convert($0, toHaveTrait: .boldFontMask) }
            case .emphasis:
                fonts(r) { fm.convert($0, toHaveTrait: .italicFontMask) }
            case .strikethrough:
                lm.addTemporaryAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: r)
                color(Theme.markdownMuted, r)
            case .code:
                // The background is drawn by the layout manager, line by line (see inlineCode).
                if !baseIsMono { fonts(r) { NSFont.monospacedSystemFont(ofSize: $0.pointSize, weight: .regular) } }
            case .alert:
                color(Theme.text, r)   // alerts read as normal text, not a muted quote
            case .alertTitle(let kind):
                fonts(r) { fm.convert($0, toHaveTrait: .boldFontMask) }
                color(Theme.markdownAlert(kind), r)
            case .codeBlock, .table:
                if !baseIsMono { fonts(r) { _ in mono } }
            case .link, .image, .footnoteReference:
                color(Theme.link, r)
            case .autolink:
                color(Theme.link, r)
                lm.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: r)
            case .math:
                color(Theme.markdownMath, r)
            case .html:
                color(Theme.markdownHTML, r)
            case .blockQuote:
                color(Theme.markdownMuted, r)
            case .frontMatter, .thematicBreak:
                color(Theme.markdownMarker, r)
            case .taskItem(let checked):
                if checked { color(Theme.markdownMuted, r) }
            case .marker:
                break
            }
        }

        // Markers: dimmed. List bullets stay a little stronger so lists remain readable.
        for s in inRegion {
            guard case .marker(let m) = s.kind else { continue }
            let r = NSIntersectionRange(s.range, region)
            guard r.length > 0 else { continue }
            color(m == .bullet || m == .task ? Theme.markdownMuted : Theme.markdownMarker, r)
        }

        // Paragraph styles: hanging indents under list and quote markers, space above headings.
        applyParagraphStyles(region, storage: storage, base: base, basePara: basePara, headingLines: headingLines)
        storage.endEditing()

        lm.inlineCode = spans.compactMap { s in s.kind == .code ? s.range : nil }
        let alerts = spans.compactMap { s -> (NSRange, String)? in if case .alert(let k) = s.kind { return (s.range, k) }; return nil }
        var quotes: [NSRange] = []
        lm.markdownBlocks = spans.compactMap { s in
            switch s.kind {
            case .codeBlock(let info):
                let lang = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
                if live, lang == "math" || Markdown.diagramEngine(info: lang) != nil { return nil }
                return InvisiblesLayoutManager.MarkdownBlock(range: s.range, kind: .code)
            case .blockQuote where live:
                let depth = quotes.filter { NSLocationInRange(s.range.location, $0) }.count
                quotes.append(s.range)
                let alert = alerts.first { $0.0 == s.range }.map { Theme.markdownAlert($0.1) }
                return InvisiblesLayoutManager.MarkdownBlock(range: s.range, kind: .quote, indent: CGFloat(depth) * Self.quoteIndent, color: alert)
            default:
                return nil
            }
        }
        lm.invalidateDisplay(forCharacterRange: region)
        tv.needsDisplay = true
    }

    // MARK: Live Preview

    /// True while edits are waiting for the next parse (spans are out of date).
    var hasPendingEdits: Bool { dirty != nil }

    /// Recomputes which markup is hidden for the selection, re-laying out what changed.
    func updateLive(selection: NSRange, alsoInvalidate extra: [NSRange] = []) {
        guard let fm = layoutManager?.foldManager, let storage else { return }
        guard live else {
            if !fm.markup.isEmpty { fm.setMarkup([], changed: [NSRange(location: 0, length: storage.length)]) }
            revealed = []
            return
        }
        let ns = storage.string as NSString
        let length = ns.length
        let sel = NSRange(location: min(selection.location, length), length: min(selection.length, length - min(selection.location, length)))
        let active = ns.lineRange(for: sel)
        func touches(_ block: NSRange) -> Bool {
            NSIntersectionRange(block, active).length > 0 || NSLocationInRange(active.location, block)
                || (block.length == 0 && NSLocationInRange(block.location, active))
        }
        var markup: [FoldManager.Markup] = []
        var shown: [NSRange] = []
        // Pictures first: markers inside them are covered by the picture.
        let widgetMarkup = widgetMarkup(ns: ns, touches: touches)
        markup += widgetMarkup
        func inWidget(_ r: NSRange) -> Bool {
            widgetMarkup.contains { NSIntersectionRange($0.range, r).length > 0 }
        }
        for s in spans {
            guard case .marker(let m) = s.kind else { continue }
            if inWidget(s.range) { continue }
            if touches(s.block) {
                if shown.last != s.block { shown.append(s.block) }
                continue
            }
            switch m {
            case .bullet:
                if s.range.length > 0, [45, 42, 43].contains(ns.character(at: s.range.location)) {
                    markup.append(.init(range: NSRange(location: s.range.location, length: 1), style: .bullet))
                }
            case .task:
                let checked = s.range.length > 1 && [120, 88].contains(ns.character(at: s.range.location + 1))
                markup.append(.init(range: s.range, style: .checkbox(checked: checked)))
            case .rule:
                markup.append(.init(range: s.range, style: .rule))
            case .table:
                break
            default:
                markup.append(.init(range: s.range, style: .hidden))
            }
        }
        markup.sort { $0.range.location < $1.range.location }
        let changed = revealed + shown + extra
        revealed = shown
        fm.checkboxWidth = ceil(Prefs.font.pointSize * 1.6)
        fm.setMarkup(markup, changed: changed)
    }

    /// Images, math and diagrams outside the active blocks, drawn as pictures once
    /// they have rendered.
    private func widgetMarkup(ns: NSString, touches: (NSRange) -> Bool) -> [FoldManager.Markup] {
        guard let tv = textView else { return [] }
        let dark = tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fontSize = (Prefs.font.pointSize * 1.08).rounded()
        let maxWidth = max(120, tv.bounds.width - tv.textContainerInset.width * 2 - 40)
        var out: [FoldManager.Markup] = []
        var waiting: [NSRange] = []

        func add(_ s: MarkdownSpan, _ kind: MarkdownWidgets.Kind, block: Bool, maxHeight: CGFloat) {
            guard !touches(s.block) else { return }
            guard let (id, image) = widgets.picture(kind, dark: dark, fontSize: fontSize) else { waiting.append(s.range); return }
            var size = image.size
            let scale = min(1, maxWidth / max(size.width, 1), maxHeight / max(size.height, 1))
            size = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            out.append(.init(range: s.range, style: .widget(id: id, size: size, block: block)))
        }
        for s in spans {
            switch s.kind {
            case .codeBlock(let info):
                let lang = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
                let engine = Markdown.diagramEngine(info: lang)
                guard lang == "math" || engine != nil else { continue }
                var lines = ns.substring(with: s.range).components(separatedBy: "\n")
                guard lines.count >= 2 else { continue }
                lines.removeFirst()
                if let last = lines.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("```") || last.hasPrefix("~~~") || last == "$$" { lines.removeLast() }
                let source = lines.joined(separator: "\n")
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                add(s, engine.map { .diagram($0, source) } ?? .math(source, display: true), block: true, maxHeight: 900)
            case .math(let display):
                let d = display ? 2 : 1
                guard s.range.length > 2 * d else { continue }
                let tex = ns.substring(with: NSRange(location: s.range.location + d, length: s.range.length - 2 * d))
                let alone = s.block == s.range
                add(s, .math(tex, display: display), block: display && alone, maxHeight: display ? 400 : Prefs.font.pointSize * 2.6)
            case .image(let raw):
                guard let url = imageURL(raw) else { continue }
                let alone = s.block == s.range
                // The file's date is part of the key, so an edited image is drawn afresh.
                let modified = url.isFileURL ? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate : nil
                add(s, .image(url, modified: modified), block: false, maxHeight: alone ? 420 : Prefs.font.pointSize * 1.6)
            default:
                continue
            }
        }
        waitingForWidgets = waiting
        return out
    }

    private func imageURL(_ raw: String) -> URL? {
        if let u = URL(string: raw), let scheme = u.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) { return u }
        guard let base = baseURL?() else { return nil }
        let decoded = raw.removingPercentEncoding ?? raw
        return URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
    }

    /// The link, image or autolink URL at a character index, for ⌘-click.
    func linkURL(at index: Int, base: URL?) -> URL? {
        for s in spans.reversed() where NSLocationInRange(index, s.range) {
            let raw: String
            switch s.kind {
            case .link(let url), .image(let url), .autolink(let url): raw = url
            default: continue
            }
            if let u = URL(string: raw), u.scheme != nil { return u }
            if let base, let u = URL(string: raw, relativeTo: base) { return u.absoluteURL }
            return nil
        }
        return nil
    }

    private func applyParagraphStyles(_ region: NSRange, storage: NSTextStorage, base: NSFont, basePara: NSParagraphStyle, headingLines: [Int: Int]) {
        let ns = storage.string as NSString
        // Where each line's text starts after quote, list and task markers.
        var prefixEnd: [Int: Int] = [:]
        var quoteDepth: [Int: Int] = [:]
        var quoteEnd: [Int: Int] = [:]
        for s in spans {
            guard case .marker(let m) = s.kind, m == .quote || m == .bullet || m == .task, NSIntersectionRange(s.block, region).length > 0 || NSLocationInRange(s.range.location, region) else { continue }
            let line = ns.lineRange(for: NSRange(location: s.range.location, length: 0)).location
            prefixEnd[line] = max(prefixEnd[line] ?? 0, NSMaxRange(s.range))
            if m == .quote {
                quoteDepth[line, default: 0] += 1
                quoteEnd[line] = max(quoteEnd[line] ?? 0, NSMaxRange(s.range))
            }
        }
        var i = region.location
        while i < NSMaxRange(region) {
            let line = ns.lineRange(for: NSRange(location: i, length: 0))
            defer { i = NSMaxRange(line) == i ? i + 1 : NSMaxRange(line) }
            var end = line.location
            while end < NSMaxRange(line), [32, 9].contains(ns.character(at: end)) { end += 1 }
            if let p = prefixEnd[line.location], p > end { end = p }
            func width(_ from: Int, _ to: Int) -> CGFloat {
                to > from ? ns.substring(with: NSRange(location: from, length: to - from)).size(withAttributes: [.font: base]).width : 0
            }
            var indent = width(line.location, end)
            var firstIndent: CGFloat = 0
            if live, let depth = quoteDepth[line.location], let qEnd = quoteEnd[line.location] {
                // Quote markers are hidden away from the cursor; leave room for the bars instead.
                firstIndent = CGFloat(depth) * Self.quoteIndent
                indent = firstIndent + width(qEnd, end)
            }
            let level = headingLines[line.location]
            guard indent > 0 || level != nil else { continue }
            let para = basePara.mutableCopy() as! NSMutableParagraphStyle
            para.headIndent = indent
            para.firstLineHeadIndent = firstIndent
            if let level, line.location > 0 { para.paragraphSpacingBefore = base.pointSize * (level <= 2 ? 0.9 : 0.5) }
            storage.addAttribute(.paragraphStyle, value: para, range: line)
        }
    }
}
