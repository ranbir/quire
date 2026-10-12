import Foundation

/// A compact Markdown → HTML renderer covering CommonMark's common
/// constructs plus GitHub tables, task lists and strikethrough.
public enum Markdown {

    public static func html(_ source: String) -> String {
        var lines = TextCodec.normalizeLineEndings(source).components(separatedBy: "\n")
        let refs = extractReferences(&lines)
        return Renderer(refs: refs).blocks(lines)
    }

    // MARK: Escaping

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        return out
    }

    // MARK: Reference definitions  [id]: url "title"

    static let refDef = try! NSRegularExpression(pattern: #"^ {0,3}\[([^\]]+)\]:\s*<?(\S+?)>?(?:\s+["'(](.*)["')])?\s*$"#)

    static func extractReferences(_ lines: inout [String]) -> [String: (String, String?)] {
        var refs: [String: (String, String?)] = [:]
        var inFence = false
        lines = lines.filter { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") { inFence.toggle() }
            guard !inFence, let m = refDef.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return true }
            let ns = line as NSString
            let title = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : nil
            refs[ns.substring(with: m.range(at: 1)).lowercased()] = (ns.substring(with: m.range(at: 2)), title)
            return false
        }
        return refs
    }

    // MARK: Block renderer

    struct Renderer {
        let refs: [String: (String, String?)]

        static let atx = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$"#)
        static let hr = try! NSRegularExpression(pattern: #"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
        static let listItem = try! NSRegularExpression(pattern: #"^( {0,3})([-*+]|\d{1,9}[.)])([ \t]+|$)"#)
        static let fence = try! NSRegularExpression(pattern: #"^( {0,3})(`{3,}|~{3,})[ \t]*([^`\s]*)"#)
        static let tableSep = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$"#)
        static let htmlBlock = try! NSRegularExpression(pattern: #"^ {0,3}<(?:/?(?:address|article|aside|blockquote|details|div|dl|fieldset|figure|footer|form|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|summary|table|tbody|td|th|thead|tr|ul|script|style|iframe|video|audio|img|picture|br)\b|!--)"#, options: .caseInsensitive)

        func match(_ r: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
            r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
        }

        func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : (s as NSString).substring(with: r)
        }

        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

        func indentWidth(_ s: String) -> Int {
            var w = 0
            for ch in s { if ch == " " { w += 1 } else if ch == "\t" { w += 4 - w % 4 } else { break } }
            return w
        }

        /// Removes up to `n` columns of leading indentation.
        func dedent(_ s: String, _ n: Int) -> String {
            var w = 0
            var idx = s.startIndex
            while idx < s.endIndex, w < n {
                if s[idx] == " " { w += 1 } else if s[idx] == "\t" { w += 4 - w % 4 } else { break }
                idx = s.index(after: idx)
            }
            return String(s[idx...])
        }

        func startsBlock(_ line: String) -> Bool {
            match(Self.atx, line) != nil || match(Self.hr, line) != nil || match(Self.fence, line) != nil
                || line.trimmingCharacters(in: .whitespaces).hasPrefix(">") || match(Self.listItem, line) != nil
                || match(Self.htmlBlock, line) != nil
        }

        func blocks(_ lines: [String]) -> String {
            var out = ""
            var i = 0
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) { i += 1; continue }

                // Fenced code
                if let m = match(Self.fence, line) {
                    let marker = group(m, 2, line)!
                    let lang = group(m, 3, line) ?? ""
                    let fenceIndent = group(m, 1, line)?.count ?? 0
                    var code: [String] = []
                    i += 1
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix(String(marker.first!)) && t.allSatisfy({ $0 == marker.first! }) && t.count >= marker.count { i += 1; break }
                        code.append(dedent(lines[i], fenceIndent))
                        i += 1
                    }
                    let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                    out += "<pre><code\(cls)>\(escape(code.joined(separator: "\n")))\(code.isEmpty ? "" : "\n")</code></pre>\n"
                    continue
                }

                // Indented code
                if indentWidth(line) >= 4 {
                    var code: [String] = []
                    while i < lines.count, indentWidth(lines[i]) >= 4 || isBlank(lines[i]) {
                        code.append(dedent(lines[i], 4)); i += 1
                    }
                    while let last = code.last, isBlank(last) { code.removeLast() }
                    out += "<pre><code>\(escape(code.joined(separator: "\n")))\n</code></pre>\n"
                    continue
                }

                // ATX heading
                if let m = match(Self.atx, line) {
                    let level = group(m, 1, line)!.count
                    let text = group(m, 2, line) ?? ""
                    out += "<h\(level) id=\"\(slug(text))\">\(inline(text))</h\(level)>\n"
                    i += 1; continue
                }

                // Thematic break
                if match(Self.hr, line) != nil { out += "<hr>\n"; i += 1; continue }

                // Blockquote
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var inner: [String] = []
                    while i < lines.count, !isBlank(lines[i]) {
                        var t = lines[i].trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix(">") { t.removeFirst(); if t.hasPrefix(" ") { t.removeFirst() } }
                        else if startsBlock(lines[i]) { break }
                        inner.append(t); i += 1
                    }
                    out += "<blockquote>\n\(blocks(inner))</blockquote>\n"
                    continue
                }

                // Lists
                if match(Self.listItem, line) != nil {
                    out += list(lines, &i)
                    continue
                }

                // Raw HTML block
                if match(Self.htmlBlock, line) != nil {
                    while i < lines.count, !isBlank(lines[i]) { out += lines[i] + "\n"; i += 1 }
                    continue
                }

                // Table
                if line.contains("|"), i + 1 < lines.count, match(Self.tableSep, lines[i + 1]) != nil, lines[i + 1].contains("-") {
                    out += table(lines, &i)
                    continue
                }

                // Paragraph (with setext heading detection)
                var para: [String] = []
                while i < lines.count, !isBlank(lines[i]) {
                    let l = lines[i]
                    if !para.isEmpty {
                        let t = l.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty && t.allSatisfy({ $0 == "=" }) {
                            let text = para.joined(separator: " ")
                            out += "<h1 id=\"\(slug(text))\">\(inline(text))</h1>\n"; para = []; i += 1; break
                        }
                        if t.count >= 2 && t.allSatisfy({ $0 == "-" }) {
                            let text = para.joined(separator: " ")
                            out += "<h2 id=\"\(slug(text))\">\(inline(text))</h2>\n"; para = []; i += 1; break
                        }
                        if interruptsParagraph(l) { break }
                    }
                    para.append(l)
                    i += 1
                }
                if !para.isEmpty {
                    out += "<p>\(paragraphInline(para))</p>\n"
                }
            }
            return out
        }

        func paragraphInline(_ lines: [String]) -> String {
            lines.enumerated().map { idx, l -> String in
                var s = l.trimmingCharacters(in: .whitespaces)
                var hardBreak = false
                if idx < lines.count - 1 {
                    if l.hasSuffix("  ") { hardBreak = true }
                    else if s.hasSuffix("\\") { hardBreak = true; s.removeLast() }
                }
                return inline(s) + (hardBreak ? "<br>" : "")
            }.joined(separator: "\n")
        }

        /// Only bullets and lists starting at 1 may interrupt a paragraph.
        func interruptsParagraph(_ l: String) -> Bool {
            guard startsBlock(l) else { return false }
            guard let m = match(Self.listItem, l) else { return true }
            let marker = group(m, 2, l)!
            return !marker.first!.isNumber || marker.dropLast() == "1"
        }

        func list(_ lines: [String], _ i: inout Int) -> String {
            guard let first = match(Self.listItem, lines[i]) else { return "" }
            let marker = group(first, 2, lines[i])!
            let ordered = marker.first!.isNumber
            let start = ordered ? Int(marker.dropLast()) ?? 1 : 1
            var items: [[String]] = []
            var loose = false
            var sawBlank = false

            while i < lines.count {
                let line = lines[i]
                if let m = match(Self.listItem, line), (group(m, 1, line)?.count ?? 0) < 4 {
                    let mk = group(m, 2, line)!
                    if mk.first!.isNumber != ordered { break }
                    if sawBlank && !items.isEmpty { loose = true }
                    sawBlank = false
                    let contentIndent = m.range.length
                    let content = (line as NSString).substring(from: m.range.length)
                    var item = [content]
                    i += 1
                    // Continuation lines
                    while i < lines.count {
                        let l = lines[i]
                        if isBlank(l) {
                            // Blank lines continue the item only if followed by indented content.
                            var j = i
                            while j < lines.count, isBlank(lines[j]) { j += 1 }
                            if j < lines.count, indentWidth(lines[j]) >= max(2, contentIndent) {
                                item.append(""); i += 1; sawBlank = true; continue
                            }
                            sawBlank = true
                            break
                        }
                        if indentWidth(l) >= max(2, contentIndent) {
                            item.append(dedent(l, contentIndent))
                        } else if match(Self.listItem, l) != nil || startsBlock(l) {
                            break
                        } else {
                            item.append(l.trimmingCharacters(in: .whitespaces))   // lazy continuation
                        }
                        i += 1
                    }
                    items.append(item)
                    if sawBlank {
                        // Skip blanks; list continues if the next line is another item.
                        while i < lines.count, isBlank(lines[i]) { i += 1 }
                        if i < lines.count, let m2 = match(Self.listItem, lines[i]), group(m2, 2, lines[i])!.first!.isNumber == ordered { continue }
                        break
                    }
                } else {
                    break
                }
            }

            let tag = ordered ? "ol" : "ul"
            var out = ordered && start != 1 ? "<ol start=\"\(start)\">\n" : "<\(tag)>\n"
            for item in items {
                var content = item
                var checkbox = ""
                if let f = content.first, f.hasPrefix("[ ] ") || f.hasPrefix("[x] ") || f.hasPrefix("[X] ") {
                    checkbox = f.hasPrefix("[ ]") ? "<input type=\"checkbox\" disabled> " : "<input type=\"checkbox\" checked disabled> "
                    content[0] = String(f.dropFirst(4))
                }
                let hasInnerBlocks = content.dropFirst().contains { match(Self.listItem, $0) != nil || startsBlock($0) } || content.contains("")
                if !loose && !hasInnerBlocks {
                    out += "<li>\(checkbox)\(paragraphInline(content))</li>\n"
                } else if !loose {
                    // Tight item with nested blocks: first paragraph unwrapped.
                    var firstPara: [String] = []
                    var k = 0
                    while k < content.count, !isBlank(content[k]), k == 0 || !(match(Self.listItem, content[k]) != nil || startsBlock(content[k])) {
                        firstPara.append(content[k]); k += 1
                    }
                    out += "<li>\(checkbox)\(paragraphInline(firstPara))\n\(blocks(Array(content[k...])))</li>\n"
                } else {
                    var rendered = blocks(content)
                    if !checkbox.isEmpty, rendered.hasPrefix("<p>") { rendered = "<p>" + checkbox + rendered.dropFirst(3) }
                    out += "<li>\n\(rendered)</li>\n"
                }
            }
            return out + "</\(tag)>\n"
        }

        func cells(_ line: String) -> [String] {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
            var cells: [String] = []
            var current = ""
            var prevBackslash = false
            for ch in t {
                if ch == "|" && !prevBackslash { cells.append(current); current = "" }
                else { current.append(ch) }
                prevBackslash = ch == "\\"
            }
            cells.append(current)
            return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
        }

        func table(_ lines: [String], _ i: inout Int) -> String {
            let header = cells(lines[i])
            let aligns: [String] = cells(lines[i + 1]).map { c in
                let l = c.hasPrefix(":"), r = c.hasSuffix(":")
                return l && r ? " style=\"text-align:center\"" : r ? " style=\"text-align:right\"" : l ? " style=\"text-align:left\"" : ""
            }
            i += 2
            var out = "<table>\n<thead>\n<tr>"
            for (k, h) in header.enumerated() { out += "<th\(k < aligns.count ? aligns[k] : "")>\(inline(h))</th>" }
            out += "</tr>\n</thead>\n<tbody>\n"
            while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
                let row = cells(lines[i])
                out += "<tr>"
                for k in 0..<header.count {
                    out += "<td\(k < aligns.count ? aligns[k] : "")>\(k < row.count ? inline(row[k]) : "")</td>"
                }
                out += "</tr>\n"
                i += 1
            }
            return out + "</tbody>\n</table>\n"
        }

        // MARK: Inline

        static let codeSpan = try! NSRegularExpression(pattern: #"(`+)(.+?)(?<!`)\1(?!`)"#, options: .dotMatchesLineSeparators)
        static let escapeChar = try! NSRegularExpression(pattern: #"\\([\\`*_{}\[\]()#+\-.!|~<>"])"#)
        static let autolink = try! NSRegularExpression(pattern: #"<((?:https?|ftp|mailto):[^\s<>]+|[\w.+-]+@[\w-]+\.[\w.-]+)>"#)
        static let rawTag = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9-]*(?:\s+[^<>]*)?/?>|<!--.*?-->"#)
        static let image = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]*)>?(?:\s+"([^"]*)")?\s*\)"#)
        static let link = try! NSRegularExpression(pattern: #"\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*<?([^)\s>]*)>?(?:\s+"([^"]*)")?\s*\)"#)
        static let refLink = try! NSRegularExpression(pattern: #"(!?)\[([^\]]+)\](?:\[([^\]]*)\])?"#)
        static let bareURL = try! NSRegularExpression(pattern: #"(?<![="'>\w/])(https?://[^\s<]+[^\s<.,:;"')\]!?])"#)

        func inline(_ text: String) -> String {
            var stash: [String] = []
            func hold(_ html: String) -> String { stash.append(html); return "\u{1}\(stash.count - 1)\u{2}" }

            func replace(_ r: NSRegularExpression, in s: String, _ f: (NSTextCheckingResult, NSString) -> String) -> String {
                let ns = s as NSString
                var out = ""
                var last = 0
                for m in r.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                    out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    out += f(m, ns)
                    last = NSMaxRange(m.range)
                }
                return out + ns.substring(from: last)
            }
            func g(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String? {
                m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
            }

            var s = text
            s = replace(Self.codeSpan, in: s) { m, ns in
                var code = ns.substring(with: m.range(at: 2))
                if code.hasPrefix(" ") && code.hasSuffix(" ") && code.trimmingCharacters(in: .whitespaces).count > 0 { code = String(code.dropFirst().dropLast()) }
                return hold("<code>\(escape(code))</code>")
            }
            s = replace(Self.escapeChar, in: s) { m, ns in hold(escape(ns.substring(with: m.range(at: 1)))) }
            s = replace(Self.autolink, in: s) { m, ns in
                let url = ns.substring(with: m.range(at: 1))
                let href = url.contains("@") && !url.contains(":") ? "mailto:\(url)" : url
                return hold("<a href=\"\(escape(href))\">\(escape(url))</a>")
            }
            s = replace(Self.rawTag, in: s) { m, ns in hold(ns.substring(with: m.range)) }
            s = replace(Self.image, in: s) { m, ns in
                let title = g(m, 3, ns).map { " title=\"\(escape($0))\"" } ?? ""
                return hold("<img src=\"\(escape(g(m, 2, ns) ?? ""))\" alt=\"\(escape(g(m, 1, ns) ?? ""))\"\(title)>")
            }
            s = replace(Self.link, in: s) { m, ns in
                let title = g(m, 3, ns).map { " title=\"\(escape($0))\"" } ?? ""
                return hold("<a href=\"\(escape(g(m, 2, ns) ?? ""))\"\(title)>") + (g(m, 1, ns) ?? "") + hold("</a>")
            }
            s = replace(Self.refLink, in: s) { m, ns in
                let label = ns.substring(with: m.range(at: 2))
                let id = (g(m, 3, ns).flatMap { $0.isEmpty ? nil : $0 } ?? label).lowercased()
                guard let (url, title) = refs[id] else { return ns.substring(with: m.range) }
                let t = title.map { " title=\"\(escape($0))\"" } ?? ""
                if g(m, 1, ns) == "!" { return hold("<img src=\"\(escape(url))\" alt=\"\(escape(label))\"\(t)>") }
                return hold("<a href=\"\(escape(url))\"\(t)>") + label + hold("</a>")
            }
            s = replace(Self.bareURL, in: s) { m, ns in
                let url = ns.substring(with: m.range(at: 1))
                return hold("<a href=\"\(escape(url))\">\(escape(url))</a>")
            }

            s = escape(s)
            // Emphasis, strongest first.
            for (pattern, tag) in [(#"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#, "strong><em"), (#"___(?=\S)(.+?)(?<=\S)___"#, "strong><em"),
                                   (#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "strong"), (#"(?<![\w])__(?=\S)(.+?)(?<=\S)__(?![\w])"#, "strong"),
                                   (#"~~(?=\S)(.+?)(?<=\S)~~"#, "del"),
                                   (#"\*(?=[^\s*])(.+?)(?<=[^\s*])\*"#, "em"), (#"(?<![\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w])"#, "em")] {
                let r = try! NSRegularExpression(pattern: pattern)
                let close = tag == "strong><em" ? "em></strong" : tag
                s = r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "<\(tag)>$1</\(close)>")
            }

            // Restore held fragments (they may nest, so loop).
            let token = try! NSRegularExpression(pattern: "\u{1}(\\d+)\u{2}")
            while s.contains("\u{1}") {
                s = replace(token, in: s) { m, ns in stash[Int(ns.substring(with: m.range(at: 1)))!] }
            }
            return s
        }
    }

    /// Wraps rendered HTML in a full page with a readable stylesheet.
    public static func page(body: String, title: String, baseURL: URL? = nil) -> String {
        let base = baseURL.map { "<base href=\"\(escape($0.absoluteString))\">" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8">\(base)<title>\(escape(title))</title>
        <meta name="color-scheme" content="light dark">
        <style>
        :root { color-scheme: light dark; --fg:#1d1d1f; --bg:#fff; --muted:#6e6e73; --code:#f3f3f5; --border:#d8d8dc; --link:#0b65d8; }
        @media (prefers-color-scheme: dark) { :root { --fg:#e6e6e8; --bg:#1e1f22; --muted:#9a9aa0; --code:#2a2b30; --border:#3a3b40; --link:#6aa8ff; } }
        body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg); background: var(--bg);
               max-width: 820px; margin: 0 auto; padding: 28px 32px 80px; }
        h1, h2 { border-bottom: 1px solid var(--border); padding-bottom: .25em; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 1.4em 0 .6em; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: 0.88em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: .15em .35em; border-radius: 4px; }
        pre { background: var(--code); padding: 14px 16px; border-radius: 8px; overflow: auto; line-height: 1.45; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding: 0 1em; color: var(--muted); border-left: 4px solid var(--border); }
        table { border-collapse: collapse; margin: 1em 0; } th, td { border: 1px solid var(--border); padding: 6px 12px; }
        th { background: var(--code); } img { max-width: 100%; } hr { border: 0; border-top: 1px solid var(--border); margin: 2em 0; }
        li > input[type=checkbox] { margin-right: .4em; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}
