import Foundation

/// Text edits behind Quire's Markdown editing commands. Each returns the range to replace,
/// the replacement and the selection afterwards (UTF-16, in the original text's coordinates
/// for the range, and in the edited text's coordinates for the selection).
public enum MarkdownEditing {

    public struct Edit: Equatable {
        public var range: NSRange
        public var replacement: String
        public var selection: NSRange

        public init(range: NSRange, replacement: String, selection: NSRange) {
            self.range = range
            self.replacement = replacement
            self.selection = selection
        }
    }

    // MARK: Return in lists and quotes

    static let listItem = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)
    static let quotePrefix = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)+"#)

    /// Return pressed with the cursor at `cursor` and nothing selected: continues a list item
    /// or quote on the next line, or ends the list/quote when the current item is empty.
    /// Nil means an ordinary new line.
    public static func newline(in text: String, cursor: Int) -> Edit? {
        let ns = text as NSString
        let line = lineRange(ns, cursor)
        let lineText = ns.substring(with: line)
        let full = NSRange(location: 0, length: (lineText as NSString).length)
        let column = cursor - line.location
        if let m = listItem.firstMatch(in: lineText, range: full), column >= m.range.length {
            let lt = lineText as NSString
            let indent = lt.substring(with: m.range(at: 1))
            let rest = lt.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                // An empty item ends the list: drop its marker (a nested one moves out a level instead).
                if !indent.isEmpty {
                    let out = String(indent.dropLast(min(indent.count, indentWidth(indent) >= 4 ? 4 : indent.count)))
                    let replacement = out + lt.substring(with: NSRange(location: m.range(at: 1).length, length: m.range.length - m.range(at: 1).length))
                    return Edit(range: NSRange(location: line.location, length: m.range.length), replacement: replacement,
                                selection: NSRange(location: line.location + (replacement as NSString).length, length: 0))
                }
                return Edit(range: NSRange(location: line.location, length: line.length), replacement: "",
                            selection: NSRange(location: line.location, length: 0))
            }
            var marker = lt.substring(with: m.range(at: 2))
            if m.range(at: 3).location != NSNotFound, let n = Int(lt.substring(with: m.range(at: 3))) {
                marker = "\(n + 1)" + lt.substring(with: m.range(at: 4))
            }
            let task = m.range(at: 6).location != NSNotFound ? "[ ] " : ""
            let insert = "\n" + indent + marker + lt.substring(with: m.range(at: 5)) + task
            return Edit(range: NSRange(location: cursor, length: 0), replacement: insert,
                        selection: NSRange(location: cursor + (insert as NSString).length, length: 0))
        }
        if let m = quotePrefix.firstMatch(in: lineText, range: full), column >= m.range.length {
            let prefix = (lineText as NSString).substring(with: m.range)
            let rest = (lineText as NSString).substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                return Edit(range: NSRange(location: line.location, length: line.length), replacement: "",
                            selection: NSRange(location: line.location, length: 0))
            }
            let insert = "\n" + (prefix.hasSuffix(" ") ? prefix : prefix + " ")
            return Edit(range: NSRange(location: cursor, length: 0), replacement: insert,
                        selection: NSRange(location: cursor + (insert as NSString).length, length: 0))
        }
        return nil
    }

    static func indentWidth(_ s: String) -> Int {
        s.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    static func lineRange(_ ns: NSString, _ i: Int) -> NSRange {
        let r = ns.lineRange(for: NSRange(location: min(i, ns.length), length: 0))
        var len = r.length
        if len > 0, ns.character(at: r.location + len - 1) == 10 { len -= 1 }
        return NSRange(location: r.location, length: len)
    }

    /// True when the line holding `cursor` is a list item.
    public static func isListItem(_ text: String, at cursor: Int) -> Bool {
        let ns = text as NSString
        let line = ns.substring(with: lineRange(ns, cursor))
        return listItem.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    // MARK: Ordered list numbering

    /// Renumbers the ordered list around `cursor` (items at the same indentation, with deeper
    /// lines between them allowed), starting from its first item's number. Nil if nothing changes.
    public static func renumber(_ text: String, around cursor: Int) -> Edit? {
        let ns = text as NSString
        let current = lineRange(ns, cursor)
        let currentText = ns.substring(with: current)
        guard let cm = listItem.firstMatch(in: currentText, range: NSRange(location: 0, length: (currentText as NSString).length)),
              cm.range(at: 3).location != NSNotFound else { return nil }
        let indent = indentWidth((currentText as NSString).substring(with: cm.range(at: 1)))
        let delimiter = (currentText as NSString).substring(with: cm.range(at: 4))

        // Lines of the list: walk up and down while lines are items at this indent, deeper
        // lines, or blank lines followed by more of the list.
        var lines: [NSRange] = []
        var i = 0
        while i < ns.length {
            let l = lineRange(ns, i)
            lines.append(l)
            i = NSMaxRange(l) + 1
        }
        if ns.length == 0 || ns.character(at: ns.length - 1) == 10 { lines.append(NSRange(location: ns.length, length: 0)) }
        guard let idx = lines.firstIndex(where: { NSLocationInRange(cursor, NSRange(location: $0.location, length: $0.length + 1)) }) else { return nil }

        enum Kind { case item(Int, NSRange), deeper, blank, other }
        func kind(_ r: NSRange) -> Kind {
            let t = ns.substring(with: r)
            if t.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
            let tr = NSRange(location: 0, length: (t as NSString).length)
            let leading = indentWidth(String(t.prefix { $0 == " " || $0 == "\t" }))
            if let m = listItem.firstMatch(in: t, range: tr), leading == indent {
                guard m.range(at: 3).location != NSNotFound, (t as NSString).substring(with: m.range(at: 4)) == delimiter else { return .other }
                return .item(Int((t as NSString).substring(with: m.range(at: 3))) ?? 1, m.range(at: 3))
            }
            return leading > indent ? .deeper : .other
        }
        var first = idx
        var j = idx - 1
        while j >= 0 {
            switch kind(lines[j]) {
            case .item: first = j
            case .deeper, .blank: break
            case .other: j = -1; continue
            }
            j -= 1
        }
        var number: Int?
        var parts: [(NSRange, String)] = []
        j = first
        while j < lines.count {
            switch kind(lines[j]) {
            case .item(let n, let digits):
                let want = number.map { $0 + 1 } ?? n
                number = want
                if n != want { parts.append((NSRange(location: lines[j].location + digits.location, length: digits.length), "\(want)")) }
            case .deeper, .blank: break
            case .other: j = lines.count; continue
            }
            j += 1
        }
        guard let firstPart = parts.first, let lastPart = parts.last else { return nil }
        let span = NSRange(location: firstPart.0.location, length: NSMaxRange(lastPart.0) - firstPart.0.location)
        var replacement = ""
        var pos = span.location
        for (r, s) in parts {
            replacement += ns.substring(with: NSRange(location: pos, length: r.location - pos)) + s
            pos = NSMaxRange(r)
        }
        // Keep the cursor where it was relative to the text.
        let shift = parts.filter { $0.0.location < cursor }.reduce(0) { $0 + ($1.1 as NSString).length - $1.0.length }
        return Edit(range: span, replacement: replacement, selection: NSRange(location: cursor + shift, length: 0))
    }

    // MARK: Inline formatting

    /// Wraps the selection in `marker` (`**`, `*`, `` ` ``, `~~`), or unwraps it when it is
    /// already wrapped. With nothing selected, wraps the word at the cursor, or inserts a pair
    /// of markers with the cursor between them.
    public static func toggleWrap(_ text: String, selection: NSRange, marker: String) -> Edit {
        let ns = text as NSString
        let m = (marker as NSString).length
        var sel = selection
        if sel.length == 0, let word = wordRange(ns, sel.location) { sel = word }

        func run(_ i: Int, forward: Bool) -> Int {
            let c = (marker as NSString).character(at: 0)
            var n = 0
            var j = forward ? i : i - 1
            while j >= 0, j < ns.length, ns.character(at: j) == c { n += 1; j += forward ? 1 : -1 }
            return n
        }
        // Markers just outside the selection: `**|bold|**`. For `*`, a run of exactly two is
        // bold, not italic.
        let before = run(sel.location, forward: false), after = run(NSMaxRange(sel), forward: true)
        let matches: (Int) -> Bool = { n in m == 1 && marker == "*" ? (n == 1 || n == 3) : n >= m }
        if sel.length > 0, matches(before), matches(after) {
            let range = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            return Edit(range: range, replacement: ns.substring(with: sel), selection: NSRange(location: sel.location - m, length: sel.length))
        }
        // Markers inside the selection: `|**bold**|`.
        let inner = ns.substring(with: sel)
        if sel.length >= 2 * m + 1, inner.hasPrefix(marker), inner.hasSuffix(marker),
           !(marker == "*" && inner.hasPrefix("**") && !inner.hasPrefix("***")) {
            let stripped = String(inner.dropFirst(marker.count).dropLast(marker.count))
            return Edit(range: sel, replacement: stripped, selection: NSRange(location: sel.location, length: (stripped as NSString).length))
        }
        return Edit(range: sel, replacement: marker + inner + marker,
                    selection: NSRange(location: sel.location + m, length: sel.length))
    }

    static func wordRange(_ ns: NSString, _ i: Int) -> NSRange? {
        func isWord(_ j: Int) -> Bool {
            guard j >= 0, j < ns.length, let u = Unicode.Scalar(ns.character(at: j)) else { return false }
            return CharacterSet.alphanumerics.contains(u) || u == "_" || u == "'"
        }
        guard isWord(i) || isWord(i - 1) else { return nil }
        var s = i, e = i
        while isWord(s - 1) { s -= 1 }
        while isWord(e) { e += 1 }
        return NSRange(location: s, length: e - s)
    }

    /// `[selection](url)`, selecting `url` (or the text, when a URL is given).
    public static func link(_ text: String, selection: NSRange, url: String?) -> Edit {
        let ns = text as NSString
        var sel = selection
        if sel.length == 0, let word = wordRange(ns, sel.location) { sel = word }
        let label = ns.substring(with: sel)
        let target = url ?? "url"
        let replacement = "[\(label)](\(target))"
        let selected = url == nil
            ? NSRange(location: sel.location + (label as NSString).length + 3, length: (target as NSString).length)
            : (label.isEmpty ? NSRange(location: sel.location + 1, length: 0) : NSRange(location: sel.location + (replacement as NSString).length, length: 0))
        return Edit(range: sel, replacement: replacement, selection: selected)
    }

    /// Sets the current line's heading level (1–6); the same level again removes it.
    public static func heading(_ text: String, cursor: Int, level: Int) -> Edit {
        let ns = text as NSString
        let line = lineRange(ns, cursor)
        let lt = ns.substring(with: line)
        let hashes = lt.prefix { $0 == "#" }.count
        var body = String(lt.dropFirst(hashes))
        if hashes > 0 { body = String(body.drop { $0 == " " || $0 == "\t" }) }
        let isHeading = hashes > 0 && hashes <= 6 && (lt.count == hashes || lt.dropFirst(hashes).first.map { $0 == " " || $0 == "\t" } == true)
        let newLine = isHeading && hashes == level ? body : String(repeating: "#", count: level) + " " + (isHeading ? body : lt)
        let oldPrefix = (lt as NSString).length - (isHeading ? (body as NSString).length : (lt as NSString).length)
        let newPrefix = (newLine as NSString).length - (isHeading ? (body as NSString).length : (lt as NSString).length)
        let caret = max(line.location, cursor - oldPrefix + newPrefix)
        return Edit(range: line, replacement: newLine, selection: NSRange(location: caret, length: 0))
    }

    /// Whether `s` is a single URL worth turning a selection into a link with.
    public static func isLinkable(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace), let url = URL(string: t), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "ftp"].contains(scheme) && (scheme == "mailto" || url.host != nil)
    }

    /// A path to `file` relative to the folder `base`, using `../` when needed; percent-encoded
    /// for a Markdown link.
    public static func relativePath(of file: URL, from base: URL) -> String {
        let f = file.standardizedFileURL.pathComponents, b = base.standardizedFileURL.pathComponents
        var i = 0
        while i < f.count, i < b.count, f[i] == b[i] { i += 1 }
        let parts = Array(repeating: "..", count: b.count - i) + f[i...]
        let path = parts.joined(separator: "/")
        return path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }
}
