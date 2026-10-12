import Foundation
import cmark_gfm
import cmark_gfm_extensions
import QuireMarkdownC

/// Options for parsing and rendering Markdown.
public struct MarkdownOptions: Equatable {
    /// GitHub's extensions (tables, task lists, strikethrough, bare-URL autolinks) and Quire's
    /// (math, Mermaid, front matter, alerts). Off gives plain CommonMark.
    public var extensions = true
    /// Footnotes (`[^1]`).
    public var footnotes = true
    /// Curly quotes, en and em dashes, ellipses.
    public var smartPunctuation = false
    /// Filter the raw HTML tags GitHub disallows (`<script>`, `<iframe>`, `<style>`…).
    public var sanitizeHTML = false

    public init(extensions: Bool = true, footnotes: Bool = true, smartPunctuation: Bool = false, sanitizeHTML: Bool = false) {
        self.extensions = extensions
        self.footnotes = footnotes
        self.smartPunctuation = smartPunctuation
        self.sanitizeHTML = sanitizeHTML
    }

    public static let `default` = MarkdownOptions()
    /// Plain CommonMark, as the spec defines it.
    public static let commonMark = MarkdownOptions(extensions: false, footnotes: false)
}

/// A Markdown document parsed with cmark-gfm (CommonMark + GitHub Flavored Markdown) plus
/// Quire's extensions: math, Mermaid, front matter, GitHub alerts and heading anchors.
/// Positions in the syntax tree are UTF-16 ranges in the original source, ready for NSTextView.
public final class MarkdownDocument {
    public let source: String
    public let options: MarkdownOptions
    /// `key: value` pairs from a YAML front matter block at the top of the file, in order.
    public let frontMatter: [(key: String, value: String)]
    /// The front matter block's range in the source, including its `---` lines.
    public let frontMatterRange: NSRange?

    /// The text handed to cmark: the source with front matter blanked and `$$` blocks turned
    /// into math fences. It has the same lines as `source`, so positions carry over.
    let prepared: String
    private lazy var lines = LineMap(original: source, prepared: prepared)

    public init(_ source: String, options: MarkdownOptions = .default) {
        self.source = source
        self.options = options
        let pre = options.extensions ? Self.prepare(source) : Prepared(text: source)
        prepared = pre.text
        frontMatter = pre.frontMatter
        frontMatterRange = pre.frontMatterRange
    }

    // MARK: Rendering

    /// The document as an HTML fragment. With `sourcePositions`, block elements carry
    /// `data-sourcepos="line:col-line:col"` (1-based lines, byte columns) for scroll sync.
    public func html(sourcePositions: Bool = false, includeFrontMatter: Bool = true) -> String {
        guard let root = parse() else { return "" }
        defer { cmark_node_free(root) }
        if options.extensions { rewriteForHTML(root) }
        let ids = headingIDs(root)
        // Always render positions internally: they key the heading anchors.
        let ext = renderExtensions()
        defer { if let ext { cmark_llist_free(cmark_get_default_mem_allocator(), ext) } }
        guard let cstr = cmark_render_html(root, renderOptions | CMARK_OPT_SOURCEPOS, ext) else { return "" }
        defer { free(cstr) }
        var html = String(cString: cstr)
        html = Self.addHeadingIDs(html, ids)
        if !sourcePositions {
            html = html.replacingOccurrences(of: #" data-sourcepos="\d+:\d+-\d+:\d+""#, with: "", options: .regularExpression)
        }
        if includeFrontMatter && !frontMatter.isEmpty {
            html = Self.frontMatterHTML(frontMatter) + html
        }
        return html
    }

    /// Headings in document order, with the anchor ids the HTML uses.
    public var headings: [MarkdownHeading] {
        guard let root = parse() else { return [] }
        defer { cmark_node_free(root) }
        var slugs = SlugSet()
        var out: [MarkdownHeading] = []
        walk(root) { node in
            guard cmark_node_get_type(node) == CMARK_NODE_HEADING else { return true }
            let text = Self.plainText(node)
            out.append(MarkdownHeading(level: Int(cmark_node_get_heading_level(node)), text: text,
                                       id: slugs.make(text), range: headingRange(range(of: node))))
            return false
        }
        return out
    }

    /// Words of readable text: markup, URLs and front matter don't count.
    public var wordCount: Int {
        guard let root = parse() else { return 0 }
        defer { cmark_node_free(root) }
        var count = 0
        walk(root) { node in
            let t = cmark_node_get_type(node)
            if t == CMARK_NODE_TEXT || t == CMARK_NODE_CODE || t == CMARK_NODE_CODE_BLOCK {
                let text = Self.literal(node)
                text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
            }
            return true
        }
        return count
    }

    /// The syntax tree with UTF-16 source ranges.
    public var root: MarkdownNode {
        guard let root = parse() else { return MarkdownNode(kind: .document, range: NSRange(location: 0, length: 0), children: []) }
        defer { cmark_node_free(root) }
        return convert(root)
    }

    // MARK: cmark plumbing

    private var parseOptions: Int32 {
        var o = CMARK_OPT_UNSAFE | CMARK_OPT_VALIDATE_UTF8
        if options.footnotes { o |= CMARK_OPT_FOOTNOTES }
        if options.smartPunctuation { o |= CMARK_OPT_SMART }
        return o
    }

    private var renderOptions: Int32 { parseOptions }

    func parse() -> UnsafeMutablePointer<cmark_node>? {
        guard let parser = cmark_parser_new(parseOptions) else { return nil }
        defer { cmark_parser_free(parser) }
        if options.extensions { quire_attach_extensions(parser, options.sanitizeHTML ? 1 : 0) }
        prepared.utf8CString.withUnsafeBufferPointer { buf in
            cmark_parser_feed(parser, buf.baseAddress, buf.count - 1)
        }
        return cmark_parser_finish(parser)
    }

    /// Extensions whose HTML filters apply when rendering: the tag filter, when sanitizing.
    private func renderExtensions() -> UnsafeMutablePointer<cmark_llist>? {
        guard options.sanitizeHTML, let tf = cmark_find_syntax_extension("tagfilter") else { return nil }
        return cmark_llist_append(cmark_get_default_mem_allocator(), nil, UnsafeMutableRawPointer(tf))
    }

    /// Visits nodes depth first; `visit` returns false to skip a node's children.
    func walk(_ node: UnsafeMutablePointer<cmark_node>, _ visit: (UnsafeMutablePointer<cmark_node>) -> Bool) {
        guard visit(node) else { return }
        var child = cmark_node_first_child(node)
        while let c = child {
            let next = cmark_node_next(c)
            walk(c, visit)
            child = next
        }
    }

    static func typeString(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        String(cString: cmark_node_get_type_string(node))
    }

    static func literal(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        if cmark_node_get_type(node) == QUIRE_NODE_MATH_INLINE || cmark_node_get_type(node) == QUIRE_NODE_MATH_DISPLAY {
            var len: Int32 = 0
            guard let p = quire_math_tex(node, &len) else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(len)), as: UTF8.self)
        }
        return cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
    }

    /// The text of a node's inline content, without markup.
    static func plainText(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        var out = ""
        func visit(_ n: UnsafeMutablePointer<cmark_node>) {
            let t = cmark_node_get_type(n)
            if t == CMARK_NODE_TEXT || t == CMARK_NODE_CODE || t == QUIRE_NODE_MATH_INLINE || t == QUIRE_NODE_MATH_DISPLAY {
                out += literal(n)
            } else if t == CMARK_NODE_SOFTBREAK || t == CMARK_NODE_LINEBREAK {
                out += " "
            }
            var c = cmark_node_first_child(n)
            while let child = c { visit(child); c = cmark_node_next(child) }
        }
        visit(node)
        return out
    }

    // MARK: Source positions

    static let setextUnderline = try! NSRegularExpression(pattern: #"^ {0,3}(=+|-+)[ \t]*$"#, options: .anchorsMatchLines)

    /// A heading's range: one line for ATX headings; for setext headings, through the
    /// underline (cmark's range can run past it).
    func headingRange(_ r: NSRange) -> NSRange {
        let ns = source as NSString
        guard r.location < ns.length else { return r }
        var i = r.location
        while i < ns.length, [32, 9].contains(ns.character(at: i)) { i += 1 }
        let firstLine = ns.lineRange(for: NSRange(location: r.location, length: 0))
        if i < ns.length, ns.character(at: i) == 35 {
            var end = NSMaxRange(firstLine)
            while end > r.location, [10, 13].contains(ns.character(at: end - 1)) { end -= 1 }
            return NSRange(location: r.location, length: end - r.location)
        }
        let after = NSRange(location: NSMaxRange(firstLine), length: max(0, min(NSMaxRange(r), ns.length) - NSMaxRange(firstLine)))
        guard let m = Self.setextUnderline.firstMatch(in: source, range: after) else { return r }
        return NSRange(location: r.location, length: NSMaxRange(m.range) - r.location)
    }

    func range(of node: UnsafeMutablePointer<cmark_node>) -> NSRange {
        let lines = self.lines
        let sl = Int(cmark_node_get_start_line(node)), sc = Int(cmark_node_get_start_column(node))
        let el = Int(cmark_node_get_end_line(node)), ec = Int(cmark_node_get_end_column(node))
        let start = lines.offset(line: sl, byteColumn: sc)
        // Some blocks end at column 0 of the next line; keep ranges off the line break.
        let end = ec == 0 && el > sl ? lines.offset(line: el - 1, byteColumn: .max) : max(start, lines.offset(line: el, byteColumn: ec + 1))
        return NSRange(location: start, length: max(0, end - start))
    }

    private func convert(_ node: UnsafeMutablePointer<cmark_node>) -> MarkdownNode {
        var children: [MarkdownNode] = []
        var c = cmark_node_first_child(node)
        while let child = c { children.append(convert(child)); c = cmark_node_next(child) }
        return MarkdownNode(kind: kind(of: node), range: range(of: node), children: children)
    }

    private func kind(of node: UnsafeMutablePointer<cmark_node>) -> MarkdownNode.Kind {
        switch cmark_node_get_type(node) {
        case CMARK_NODE_DOCUMENT: return .document
        case CMARK_NODE_BLOCK_QUOTE: return .blockQuote
        case CMARK_NODE_LIST: return .list(ordered: cmark_node_get_list_type(node) == CMARK_ORDERED_LIST)
        case CMARK_NODE_ITEM:
            return Self.typeString(node) == "tasklist" ? .item(checked: cmark_gfm_extensions_get_tasklist_item_checked(node)) : .item(checked: nil)
        case CMARK_NODE_CODE_BLOCK: return .codeBlock(info: cmark_node_get_fence_info(node).map { String(cString: $0) } ?? "")
        case CMARK_NODE_HTML_BLOCK: return .htmlBlock
        case CMARK_NODE_PARAGRAPH: return .paragraph
        case CMARK_NODE_HEADING: return .heading(level: Int(cmark_node_get_heading_level(node)))
        case CMARK_NODE_THEMATIC_BREAK: return .thematicBreak
        case CMARK_NODE_FOOTNOTE_DEFINITION: return .footnoteDefinition
        case CMARK_NODE_TEXT: return .text
        case CMARK_NODE_SOFTBREAK: return .softBreak
        case CMARK_NODE_LINEBREAK: return .lineBreak
        case CMARK_NODE_CODE: return .code
        case CMARK_NODE_HTML_INLINE: return .htmlInline
        case CMARK_NODE_EMPH: return .emphasis
        case CMARK_NODE_STRONG: return .strong
        case CMARK_NODE_LINK: return .link(url: cmark_node_get_url(node).map { String(cString: $0) } ?? "")
        case CMARK_NODE_IMAGE: return .image(url: cmark_node_get_url(node).map { String(cString: $0) } ?? "")
        case CMARK_NODE_FOOTNOTE_REFERENCE: return .footnoteReference
        case QUIRE_NODE_MATH_INLINE: return .math(display: false)
        case QUIRE_NODE_MATH_DISPLAY: return .math(display: true)
        default:
            switch Self.typeString(node) {
            case "table": return .table
            case "table_header", "table_row": return .tableRow
            case "table_cell": return .tableCell
            case "strikethrough": return .strikethrough
            case let s: return .other(s)
            }
        }
    }

    // MARK: Pre-pass

    struct Prepared {
        var text: String
        var frontMatter: [(key: String, value: String)] = []
        var frontMatterRange: NSRange?
    }

    /// Blanks a front matter block and turns `$$` lines enclosing display math into
    /// `~~~math` fences, keeping every other line (and the line count) unchanged.
    static func prepare(_ source: String) -> Prepared {
        var result = Prepared(text: source)
        let hasFrontMatter = source.hasPrefix("---")
        let hasDisplayMath = source.range(of: "$$", options: .literal) != nil
        guard hasFrontMatter || hasDisplayMath else { return result }
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var changed = false

        // Front matter: "---" on the first line, closed by "---" or "...".
        if hasFrontMatter, trimmed(lines[0]) == "---",
           let close = lines.indices.dropFirst().first(where: { ["---", "..."].contains(trimmed(lines[$0])) }), close > 1 {
            let body = lines[1..<close]
            // Require it to look like YAML so a leading thematic break followed by text isn't eaten.
            let looksLikeYAML = body.allSatisfy { l in
                let t = trimmed(l)
                return t.isEmpty || t.hasPrefix("#") || t.hasPrefix("- ") || l.first == " " || l.first == "\t"
                    || t.range(of: #"^[A-Za-z0-9_\-. "']+:(\s|$)"#, options: .regularExpression) != nil
            }
            if looksLikeYAML {
                for l in body {
                    guard l.first != " ", l.first != "\t", let colon = l.firstIndex(of: ":") else { continue }
                    let key = trimmed(l[..<colon])
                    var value = trimmed(l[l.index(after: colon)...])
                    if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                        value = String(value.dropFirst().dropLast())
                    }
                    if !key.isEmpty { result.frontMatter.append((key, value)) }
                }
                let length = lines[0...close].reduce(0) { $0 + $1.utf16.count + 1 }
                result.frontMatterRange = NSRange(location: 0, length: min(length, source.utf16.count))
                for i in 0...close { lines[i] = "" }
                changed = true
            }
        }

        // $$ blocks, outside fenced code.
        if hasDisplayMath {
            var fence: (char: UInt8, count: Int)?
            var i = 0
            while i < lines.count {
                let (indent, rest) = leading(lines[i])
                if indent >= 4 { i += 1; continue }
                if let f = fence {
                    let run = rest.prefix { $0 == f.char }.count
                    if run >= f.count, rest.dropFirst(run).allSatisfy({ $0 == 32 || $0 == 9 }) { fence = nil }
                    i += 1; continue
                }
                if let c = rest.first, c == UInt8(ascii: "`") || c == UInt8(ascii: "~") {
                    let run = rest.prefix { $0 == c }.count
                    if run >= 3 { fence = (c, run); i += 1; continue }
                }
                if isDollarLine(rest), let close = lines.indices.dropFirst(i + 1).first(where: { isDollarLine(leading(lines[$0]).rest) }) {
                    let longest = lines[(i + 1)..<close].map { leading($0).rest.prefix { $0 == UInt8(ascii: "~") }.count }.max() ?? 0
                    let marker = String(repeating: "~", count: max(3, longest + 1))
                    let pad = String(repeating: " ", count: indent)
                    lines[i] = pad + marker + "math"
                    lines[close] = pad + marker
                    changed = true
                    i = close + 1
                    continue
                }
                i += 1
            }
        }
        if changed { result.text = lines.joined(separator: "\n") }
        return result
    }

    private static func trimmed<S: StringProtocol>(_ s: S) -> String { s.trimmingCharacters(in: .whitespaces) }

    /// A line's leading spaces (tabs count to the next multiple of 4) and the bytes after them.
    private static func leading(_ line: String) -> (indent: Int, rest: Substring.UTF8View) {
        var indent = 0
        var idx = line.utf8.startIndex
        while idx < line.utf8.endIndex {
            let b = line.utf8[idx]
            if b == 32 { indent += 1 } else if b == 9 { indent += 4 - indent % 4 } else { break }
            idx = line.utf8.index(after: idx)
        }
        return (indent, line[idx...].utf8)
    }

    /// `$$` alone on a line (trailing spaces allowed).
    private static func isDollarLine(_ rest: Substring.UTF8View) -> Bool {
        var it = rest.makeIterator()
        guard it.next() == UInt8(ascii: "$"), it.next() == UInt8(ascii: "$") else { return false }
        while let b = it.next() { if b != 32 && b != 9 && b != 13 { return false } }
        return true
    }

    // MARK: HTML rewrites

    private func makeHTMLBlock(_ html: String) -> UnsafeMutablePointer<cmark_node> {
        let n = cmark_node_new(CMARK_NODE_HTML_BLOCK)!
        cmark_node_set_literal(n, html)
        return n
    }

    private static func sourcepos(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        " data-sourcepos=\"\(cmark_node_get_start_line(node)):\(cmark_node_get_start_column(node))-\(cmark_node_get_end_line(node)):\(cmark_node_get_end_column(node))\""
    }

    static let alertKinds = ["NOTE": "Note", "TIP": "Tip", "IMPORTANT": "Important", "WARNING": "Warning", "CAUTION": "Caution"]

    /// Mermaid and math code blocks, standalone display math, and GitHub alerts.
    private func rewriteForHTML(_ root: UnsafeMutablePointer<cmark_node>) {
        var replace: [(UnsafeMutablePointer<cmark_node>, [UnsafeMutablePointer<cmark_node>])] = []
        var alerts: [(UnsafeMutablePointer<cmark_node>, String)] = []
        walk(root) { node in
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_CODE_BLOCK {
                let info = (cmark_node_get_fence_info(node).map { String(cString: $0) } ?? "")
                    .split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                var code = Self.literal(node)
                if code.hasSuffix("\n") { code.removeLast() }
                if info == "mermaid" {
                    replace.append((node, [makeHTMLBlock("<pre class=\"mermaid\"\(Self.sourcepos(node))>\(Markdown.escape(code))</pre>")]))
                } else if info == "math" {
                    replace.append((node, [makeHTMLBlock("<div class=\"math math-display\"\(Self.sourcepos(node))>\(Markdown.escape(code))</div>")]))
                }
                return false
            }
            if type == CMARK_NODE_PARAGRAPH, let only = cmark_node_first_child(node), cmark_node_next(only) == nil,
               cmark_node_get_type(only) == QUIRE_NODE_MATH_DISPLAY {
                replace.append((node, [makeHTMLBlock("<div class=\"math math-display\"\(Self.sourcepos(node))>\(Markdown.escape(Self.literal(only)))</div>")]))
                return false
            }
            if type == CMARK_NODE_BLOCK_QUOTE, let kind = alertKind(node) {
                alerts.append((node, kind))
            }
            return true
        }
        for (node, with) in replace {
            for n in with { cmark_node_insert_before(node, n) }
            cmark_node_free(node)
        }
        for (quote, kind) in alerts {
            let cls = kind.lowercased()
            cmark_node_insert_before(quote, makeHTMLBlock("<div class=\"markdown-alert markdown-alert-\(cls)\"\(Self.sourcepos(quote))>\n<p class=\"markdown-alert-title\">\(Self.alertKinds[kind]!)</p>"))
            while let child = cmark_node_first_child(quote) { cmark_node_insert_before(quote, child) }
            cmark_node_insert_before(quote, makeHTMLBlock("</div>"))
            cmark_node_free(quote)
        }
    }

    /// For a block quote starting with `[!NOTE]` (etc.) alone on its first line: removes the
    /// marker from the tree and returns the alert kind.
    private func alertKind(_ quote: UnsafeMutablePointer<cmark_node>) -> String? {
        guard let para = cmark_node_first_child(quote), cmark_node_get_type(para) == CMARK_NODE_PARAGRAPH,
              let first = cmark_node_first_child(para) else { return nil }
        // cmark splits "[!NOTE]" into text nodes "[", "!NOTE", "]" (brackets are delimiters).
        var nodes: [UnsafeMutablePointer<cmark_node>] = []
        var text = ""
        var n: UnsafeMutablePointer<cmark_node>? = first
        while let cur = n, cmark_node_get_type(cur) == CMARK_NODE_TEXT {
            nodes.append(cur)
            text += Self.literal(cur)
            n = cmark_node_next(cur)
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
        let kind = String(trimmed.dropFirst(2).dropLast()).uppercased()
        guard Self.alertKinds[kind] != nil else { return nil }
        // The marker must be alone on its line: followed by a line break or nothing.
        if let after = n {
            let t = cmark_node_get_type(after)
            guard t == CMARK_NODE_SOFTBREAK || t == CMARK_NODE_LINEBREAK else { return nil }
            nodes.append(after)
        }
        for node in nodes { cmark_node_free(node) }
        if cmark_node_first_child(para) == nil { cmark_node_free(para) }
        return kind
    }

    // MARK: Heading anchors

    /// Anchor ids keyed by the heading's `data-sourcepos` value.
    private func headingIDs(_ root: UnsafeMutablePointer<cmark_node>) -> [String: String] {
        var slugs = SlugSet()
        var ids: [String: String] = [:]
        walk(root) { node in
            guard cmark_node_get_type(node) == CMARK_NODE_HEADING else { return true }
            let pos = Self.sourcepos(node)
            ids[String(pos.dropFirst(" data-sourcepos=\"".count).dropLast())] = slugs.make(Self.plainText(node))
            return false
        }
        return ids
    }

    static let headingTag = try! NSRegularExpression(pattern: #"<h([1-6]) data-sourcepos="([^"]+)">"#)

    static func addHeadingIDs(_ html: String, _ ids: [String: String]) -> String {
        guard !ids.isEmpty else { return html }
        let ns = html as NSString
        let out = NSMutableString(capacity: ns.length + ids.count * 24)
        var last = 0
        for m in headingTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let id = ids[ns.substring(with: m.range(at: 2))] else { continue }
            out.append(ns.substring(with: NSRange(location: last, length: m.range(at: 1).location + 1 - last)))
            out.append(" id=\"\(Markdown.escape(id))\"")
            last = m.range(at: 1).location + 1
        }
        out.append(ns.substring(from: last))
        return out as String
    }

    static func frontMatterHTML(_ fields: [(key: String, value: String)]) -> String {
        let rows = fields.map { "<tr><th>\(Markdown.escape($0.key))</th><td>\(Markdown.escape($0.value))</td></tr>" }.joined()
        return "<table class=\"front-matter\">\(rows)</table>\n"
    }
}

/// A heading and the anchor id its HTML gets.
public struct MarkdownHeading: Equatable {
    public var level: Int
    public var text: String
    public var id: String
    public var range: NSRange
}

/// A node of the Markdown syntax tree, with its UTF-16 range in the source.
public struct MarkdownNode: Equatable {
    public enum Kind: Equatable {
        case document, blockQuote, list(ordered: Bool), item(checked: Bool?), codeBlock(info: String), htmlBlock
        case paragraph, heading(level: Int), thematicBreak, table, tableRow, tableCell, footnoteDefinition
        case text, softBreak, lineBreak, code, htmlInline, emphasis, strong, strikethrough
        case link(url: String), image(url: String), footnoteReference, math(display: Bool), other(String)
    }
    public var kind: Kind
    public var range: NSRange
    public var children: [MarkdownNode]
}

/// GitHub's heading anchor rules: lower case, punctuation dropped (except `-` and `_`),
/// spaces become `-`, and repeats get `-1`, `-2`… suffixes.
struct SlugSet {
    private var used: [String: Int] = [:]

    static func slug(_ text: String) -> String {
        var out = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) }
            else if ch == " " { out.append("-") }
        }
        return out
    }

    mutating func make(_ text: String) -> String {
        let base = Self.slug(text)
        guard let n = used[base] else { used[base] = 1; return base }
        var k = n
        var candidate = "\(base)-\(k)"
        while used[candidate] != nil { k += 1; candidate = "\(base)-\(k)" }
        used[base] = k + 1
        used[candidate] = 1
        return candidate
    }
}

/// Converts cmark positions (1-based line, 1-based UTF-8 byte column, in the prepared text)
/// to UTF-16 offsets in the original source.
struct LineMap {
    private var starts: [Int] = []          // UTF-16 offset of each original line
    private var original: [Substring] = []
    private var prepared: [Substring] = []

    init(original source: String, prepared text: String) {
        original = source.split(separator: "\n", omittingEmptySubsequences: false)
        prepared = source == text ? original : text.split(separator: "\n", omittingEmptySubsequences: false)
        var offset = 0
        starts.reserveCapacity(original.count)
        for l in original {
            starts.append(offset)
            offset += l.utf16.count + 1
        }
    }

    /// Clamped to the line, so a range never takes in the line break.
    func offset(line: Int, byteColumn: Int) -> Int {
        guard !starts.isEmpty else { return 0 }
        let li = min(max(line - 1, 0), starts.count - 1)
        let p = prepared[li], o = original[li]
        let bytes = min(max(byteColumn - 1, 0), p.utf8.count)
        let idx = p.utf8.index(p.utf8.startIndex, offsetBy: bytes)
        let col = p.utf16.distance(from: p.utf16.startIndex, to: idx)
        return starts[li] + min(col, o.utf16.count)
    }
}
