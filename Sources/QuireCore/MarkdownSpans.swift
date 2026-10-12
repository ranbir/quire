import Foundation
import cmark_gfm
import cmark_gfm_extensions
import QuireMarkdownC

/// A formatted range of Markdown source, for styling the text in the editor.
public struct MarkdownSpan: Hashable {
    public enum Kind: Hashable {
        case heading(level: Int), strong, emphasis, strikethrough, code
        case link(url: String), image(url: String), autolink(url: String), footnoteReference
        case math(display: Bool), html
        case blockQuote, codeBlock(info: String), thematicBreak, table, frontMatter
        /// A GitHub alert (`> [!NOTE]` …): the kind is lower case, e.g. "note". Covers the quote.
        case alert(String)
        /// The alert's label, e.g. `NOTE` in `[!NOTE]`.
        case alertTitle(String)
        case taskItem(checked: Bool)
        /// Markup characters: dimmed when styling, hidden away from the cursor in Live Preview.
        case marker(Marker)
    }

    public enum Marker: Hashable {
        /// `#` runs and setext underlines
        case heading
        /// `*`, `_`, `~` around emphasis, strong and strikethrough
        case emphasis
        /// backticks around inline code
        case code
        /// `[`, `![`, `<` and `>` around link text
        case link
        /// `](url "title")`, `][ref]`
        case url
        /// `>` at the start of a quoted line
        case quote
        /// `-`, `*`, `+`, `1.` list markers
        case bullet
        /// `[ ]` and `[x]`
        case task
        /// fence lines of a code or math block
        case fence
        /// a thematic break line
        case rule
        /// `$` and `$$` around inline math
        case math
        /// the backslash of an escape like `\*`
        case escape
        /// a trailing backslash hard line break
        case lineBreak
        /// table pipes and the delimiter row
        case table
        /// `[!` and `]` around an alert's label
        case alert
    }

    public var kind: Kind
    public var range: NSRange
    /// The leaf block (paragraph, heading, code block…) or line the span belongs to.
    /// Live Preview reveals a marker when the selection touches its block.
    public var block: NSRange

    public init(kind: Kind, range: NSRange, block: NSRange) {
        self.kind = kind
        self.range = range
        self.block = block
    }
}

extension MarkdownDocument {

    /// Formatting and markup ranges for the whole document, in document order.
    public var spans: [MarkdownSpan] {
        guard let root = parse() else { return [] }
        defer { cmark_node_free(root) }
        var builder = SpanBuilder(doc: self, src: source as NSString)
        if let fm = frontMatterRange { builder.add(.frontMatter, fm, fm) }
        builder.visit(root, leaf: nil)
        return builder.spans
    }
}

private extension Character {
    init?(unicodeScalarIfASCII c: unichar) {
        guard c > 32, c < 127, let u = Unicode.Scalar(c) else { return nil }
        self.init(u)
    }
}

private struct SpanBuilder {
    let doc: MarkdownDocument
    let src: NSString
    var spans: [MarkdownSpan] = []

    init(doc: MarkdownDocument, src: NSString) {
        self.doc = doc
        self.src = src
    }

    mutating func add(_ kind: MarkdownSpan.Kind, _ range: NSRange, _ block: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= src.length else { return }
        spans.append(MarkdownSpan(kind: kind, range: range, block: block))
    }

    mutating func marker(_ m: MarkdownSpan.Marker, _ range: NSRange, _ block: NSRange) { add(.marker(m), range, block) }

    func char(_ i: Int) -> unichar { i >= 0 && i < src.length ? src.character(at: i) : 0 }

    func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }

    /// Length of the run of `c` starting at `i` (going forward) or ending before `i` (backward).
    func run(of c: unichar, at i: Int, backward: Bool = false, limit: Int = .max) -> Int {
        var n = 0
        var j = backward ? i - 1 : i
        while n < limit, char(j) == c { n += 1; j += backward ? -1 : 1 }
        return n
    }

    func lineRange(_ i: Int) -> NSRange {
        let r = src.lineRange(for: NSRange(location: min(i, src.length), length: 0))
        // without the line break
        var len = r.length
        while len > 0, [10, 13].contains(src.character(at: r.location + len - 1)) { len -= 1 }
        return NSRange(location: r.location, length: len)
    }

    /// The lines (without breaks) that `r` touches.
    func lines(in r: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var i = r.location
        repeat {
            let l = lineRange(i)
            out.append(l)
            let next = src.lineRange(for: NSRange(location: l.location, length: 0))
            i = NSMaxRange(next)
        } while i < NSMaxRange(r) && i < src.length
        return out
    }

    mutating func visit(_ node: UnsafeMutablePointer<cmark_node>, leaf: NSRange?) {
        let r = doc.range(of: node)
        let type = cmark_node_get_type(node)
        var leaf = leaf

        switch type {
        case CMARK_NODE_HEADING:
            let h = headingMarkers(r)
            leaf = h
            add(.heading(level: Int(cmark_node_get_heading_level(node))), h, h)
        case CMARK_NODE_PARAGRAPH:
            leaf = r
        case CMARK_NODE_BLOCK_QUOTE:
            add(.blockQuote, r, r)
            quoteMarkers(r)
            alertSpans(r)
        case CMARK_NODE_ITEM:
            itemMarkers(node, r)
        case CMARK_NODE_CODE_BLOCK:
            let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
            add(.codeBlock(info: info), r, r)
            fenceMarkers(r)
            return
        case CMARK_NODE_HTML_BLOCK:
            add(.html, r, r)
            return
        case CMARK_NODE_THEMATIC_BREAK:
            add(.thematicBreak, r, r)
            marker(.rule, r, r)
            return
        case CMARK_NODE_TEXT:
            // Backslash escapes (`\*`) are merged into the surrounding text.
            var i = r.location
            while i < NSMaxRange(r) {
                if char(i) == 92, let next = Character(unicodeScalarIfASCII: char(i + 1)), next.isPunctuation || next.isSymbol {
                    marker(.escape, NSRange(location: i, length: 1), leaf ?? r)
                    i += 2
                } else { i += 1 }
            }
            // A backslash hard break has no position of its own: it follows the text before it.
            if let next = cmark_node_next(node), cmark_node_get_type(next) == CMARK_NODE_LINEBREAK, char(NSMaxRange(r)) == 92 {
                marker(.lineBreak, NSRange(location: NSMaxRange(r), length: 1), leaf ?? r)
            }
            return
        case CMARK_NODE_LINEBREAK, CMARK_NODE_SOFTBREAK:
            return
        case CMARK_NODE_CODE:
            // cmark's range is the content; the backtick runs sit just outside it.
            let n = run(of: 96, at: r.location, backward: true)
            let m = run(of: 96, at: NSMaxRange(r))
            if n > 0, n == m {
                add(.code, NSRange(location: r.location - n, length: r.length + 2 * n), leaf ?? r)
                marker(.code, NSRange(location: r.location - n, length: n), leaf ?? r)
                marker(.code, NSRange(location: NSMaxRange(r), length: n), leaf ?? r)
            } else {
                add(.code, r, leaf ?? r)
            }
            return
        case CMARK_NODE_HTML_INLINE:
            add(.html, r, leaf ?? r)
            return
        case CMARK_NODE_EMPH, CMARK_NODE_STRONG:
            add(type == CMARK_NODE_EMPH ? .emphasis : .strong, r, leaf ?? r)
            delimiterMarkers(r, count: type == CMARK_NODE_EMPH ? 1 : 2, chars: [42, 95], block: leaf ?? r)
        case CMARK_NODE_LINK, CMARK_NODE_IMAGE:
            linkSpans(node, r, image: type == CMARK_NODE_IMAGE, block: leaf ?? r)
        case CMARK_NODE_FOOTNOTE_REFERENCE:
            add(.footnoteReference, r, leaf ?? r)
            return
        case QUIRE_NODE_MATH_INLINE, QUIRE_NODE_MATH_DISPLAY:
            let display = type == QUIRE_NODE_MATH_DISPLAY
            add(.math(display: display), r, leaf ?? r)
            let d = display ? 2 : 1
            if r.length > 2 * d {
                marker(.math, NSRange(location: r.location, length: d), leaf ?? r)
                marker(.math, NSRange(location: NSMaxRange(r) - d, length: d), leaf ?? r)
            }
            return
        default:
            switch MarkdownDocument.typeString(node) {
            case "strikethrough":
                add(.strikethrough, r, leaf ?? r)
                let n = min(run(of: 126, at: r.location), 2)
                delimiterMarkers(r, count: max(n, 1), chars: [126], block: leaf ?? r)
            case "table":
                leaf = r
                add(.table, r, r)
                tableMarkers(r)
            default: break
            }
        }

        var child = cmark_node_first_child(node)
        while let c = child {
            visit(c, leaf: leaf)
            child = cmark_node_next(c)
        }
    }

    /// The end of the line containing `i`, if it lies in `block`.
    func lineEnd(before i: Int, in block: NSRange) -> Int? {
        let l = lineRange(max(i, block.location))
        var end = NSMaxRange(l)
        while end > l.location, isSpace(char(end - 1)) { end -= 1 }
        return end > block.location ? end : nil
    }

    static let setextUnderline = try! NSRegularExpression(pattern: #"^ {0,3}(=+|-+)[ \t]*$"#)

    /// Marks `#` runs or the setext underline; returns the heading's range (cmark's can run
    /// past a setext underline).
    mutating func headingMarkers(_ r: NSRange) -> NSRange {
        let first = lineRange(r.location)
        var i = r.location
        while isSpace(char(i)) { i += 1 }
        if char(i) == 35 {
            // ATX: opening #s and the space after them; optional closing #s.
            let hashes = run(of: 35, at: i)
            var end = i + hashes
            while end < NSMaxRange(first), isSpace(char(end)) { end += 1 }
            let heading = NSRange(location: r.location, length: NSMaxRange(first) - r.location)
            marker(.heading, NSRange(location: i, length: end - i), heading)
            var e = NSMaxRange(first)
            while e > end, isSpace(char(e - 1)) { e -= 1 }
            let closing = run(of: 35, at: e, backward: true)
            if closing > 0, e - closing > end, isSpace(char(e - closing - 1)) {
                var s = e - closing
                while s > end, isSpace(char(s - 1)) { s -= 1 }
                marker(.heading, NSRange(location: s, length: NSMaxRange(first) - s), heading)
            }
            return heading
        }
        // Setext: the first line after the text that is all = or all -.
        for line in lines(in: r).dropFirst() where Self.setextUnderline.firstMatch(in: src as String, range: line) != nil {
            let heading = NSRange(location: r.location, length: NSMaxRange(line) - r.location)
            marker(.heading, line, heading)
            return heading
        }
        return r
    }

    mutating func quoteMarkers(_ r: NSRange) {
        let column = r.location - lineRange(r.location).location
        for line in lines(in: r) {
            var i = line.location + min(column, line.length)
            var spaces = 0
            while spaces < 3, isSpace(char(i)) { i += 1; spaces += 1 }
            guard char(i) == 62 else { continue }   // lazy continuation lines have no marker
            let len = isSpace(char(i + 1)) ? 2 : 1
            marker(.quote, NSRange(location: i, length: min(len, NSMaxRange(line) - i)), line)
        }
    }

    static let alertLine = try! NSRegularExpression(pattern: #"^[ \t]{0,3}>[ \t]?\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*$"#, options: .caseInsensitive)

    /// A quote whose first line is just `[!NOTE]` (etc.) is a GitHub alert.
    mutating func alertSpans(_ r: NSRange) {
        let first = lineRange(r.location)
        guard let m = Self.alertLine.firstMatch(in: src as String, range: first) else { return }
        let label = m.range(at: 1)
        let kind = src.substring(with: label).lowercased()
        add(.alert(kind), r, r)
        add(.alertTitle(kind), label, first)
        marker(.alert, NSRange(location: label.location - 2, length: 2), first)
        marker(.alert, NSRange(location: NSMaxRange(label), length: 1), first)
    }

    mutating func itemMarkers(_ node: UnsafeMutablePointer<cmark_node>, _ r: NSRange) {
        let line = lineRange(r.location)
        var i = r.location
        let start = i
        if [45, 42, 43].contains(char(i)) {
            i += 1
        } else {
            while char(i) >= 48 && char(i) <= 57 { i += 1 }
            guard i > start, char(i) == 46 || char(i) == 41 else { return }
            i += 1
        }
        var end = i
        while end < NSMaxRange(line), isSpace(char(end)), end - i < 4 { end += 1 }
        marker(.bullet, NSRange(location: start, length: end - start), line)
        if MarkdownDocument.typeString(node) == "tasklist", char(end) == 91, char(end + 2) == 93 {
            let checked = cmark_gfm_extensions_get_tasklist_item_checked(node)
            var after = end + 3
            if isSpace(char(after)) { after += 1 }
            add(.taskItem(checked: checked), r, line)
            marker(.task, NSRange(location: end, length: after - end), line)
        }
    }

    mutating func fenceMarkers(_ r: NSRange) {
        let first = lineRange(r.location)
        var i = first.location
        while isSpace(char(i)) { i += 1 }
        let c = char(i)
        guard c == 96 || c == 126 || c == 36 else { return }   // ` ~ or $$ (display math)
        marker(.fence, NSRange(location: i, length: NSMaxRange(first) - i), r)
        let last = lineRange(max(NSMaxRange(r) - 1, r.location))
        guard last.location > first.location else { return }
        var j = last.location
        while isSpace(char(j)) { j += 1 }
        if char(j) == c { marker(.fence, NSRange(location: j, length: NSMaxRange(last) - j), r) }
    }

    mutating func delimiterMarkers(_ r: NSRange, count: Int, chars: [unichar], block: NSRange) {
        let c = char(r.location)
        guard chars.contains(c), r.length > 2 * count,
              (0..<count).allSatisfy({ char(r.location + $0) == c && char(NSMaxRange(r) - 1 - $0) == c }) else { return }
        marker(.emphasis, NSRange(location: r.location, length: count), block)
        marker(.emphasis, NSRange(location: NSMaxRange(r) - count, length: count), block)
    }

    mutating func linkSpans(_ node: UnsafeMutablePointer<cmark_node>, _ r: NSRange, image: Bool, block: NSRange) {
        let url = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
        let label = cmark_node_first_child(node).map { MarkdownDocument.literal($0) } ?? ""
        if char(r.location) == 60, char(NSMaxRange(r) - 1) == 62, r.length >= 2 {   // <autolink>
            add(.autolink(url: url), r, block)
            marker(.link, NSRange(location: r.location, length: 1), block)
            marker(.link, NSRange(location: NSMaxRange(r) - 1, length: 1), block)
            return
        }
        let open = image ? 2 : 1
        guard char(r.location) == (image ? 33 : 91), !image || char(r.location + 1) == 91 else {
            // A bare URL (GFM autolink extension); its range can start a character early.
            let len = min(label.utf16.count, r.length)
            add(.autolink(url: url), NSRange(location: NSMaxRange(r) - len, length: len), block)
            return
        }
        add(image ? .image(url: url) : .link(url: url), r, block)
        // The label ends at the `]` after the last child.
        var labelEnd = r.location + open
        var c = cmark_node_first_child(node)
        while let child = c { labelEnd = max(labelEnd, NSMaxRange(doc.range(of: child))); c = cmark_node_next(child) }
        while labelEnd < NSMaxRange(r), char(labelEnd) != 93 { labelEnd += 1 }
        guard labelEnd < NSMaxRange(r) else { return }
        marker(.link, NSRange(location: r.location, length: open), block)
        marker(.url, NSRange(location: labelEnd, length: NSMaxRange(r) - labelEnd), block)
    }

    mutating func tableMarkers(_ r: NSRange) {
        for (n, line) in lines(in: r).enumerated() {
            if n == 1 { marker(.table, line, line); continue }   // delimiter row
            var i = line.location
            var inCode = false
            while i < NSMaxRange(line) {
                let ch = char(i)
                if ch == 92 { i += 2; continue }
                if ch == 96 { inCode.toggle() }
                if ch == 124 && !inCode { marker(.table, NSRange(location: i, length: 1), line) }
                i += 1
            }
        }
    }
}
