import Foundation

/// A foldable region. `range` is the text that gets hidden; the header line
/// (and, for bracket folds, the closing bracket) stay visible.
public struct FoldRange: Equatable, Hashable {
    public let range: NSRange
    /// 0-based line on which the fold starts.
    public let line: Int
    public init(range: NSRange, line: Int) { self.range = range; self.line = line }
}

public enum FoldScanner {
    public static func folds(in text: String, language: Language) -> [FoldRange] {
        let index = LineIndex(text)
        var result: [FoldRange]
        switch language.name {
        case "Markdown": result = headingFolds(text, index)
        case "HTML", "XML": result = tagFolds(text, index, language: language)
        case "Python", "YAML", "Plain Text", "INI / Config", "Makefile": result = indentFolds(text, index)
        default:
            result = language.indentAfter.contains("{") ? bracketFolds(text, index, language: language) : indentFolds(text, index)
        }
        return result.sorted { $0.range.location < $1.range.location || ($0.range.location == $1.range.location && $0.range.length > $1.range.length) }
    }

    /// The outermost fold beginning on each line.
    public static func foldsByLine(_ folds: [FoldRange]) -> [Int: FoldRange] {
        var byLine: [Int: FoldRange] = [:]
        for f in folds where (byLine[f.line]?.range.length ?? -1) < f.range.length { byLine[f.line] = f }
        return byLine
    }

    // MARK: Brackets, skipping strings and comments

    static func bracketFolds(_ text: String, _ index: LineIndex, language: Language) -> [FoldRange] {
        let ns = text as NSString
        let tokens = Tokenizer(language: language).tokenize(text)
        var skip = IndexSet()
        var folds: [FoldRange] = []
        for t in tokens where t.kind == .string || t.kind == .comment {
            skip.insert(integersIn: t.range.location..<NSMaxRange(t.range))
            // Multi-line block comments fold too.
            if t.kind == .comment, t.range.length > 4 {
                let l1 = index.line(for: t.range.location), l2 = index.line(for: NSMaxRange(t.range) - 1)
                if l2 > l1 {
                    let lineEnd = NSMaxRange(index.range(ofLine: l1))
                    folds.append(FoldRange(range: NSRange(location: lineEnd, length: NSMaxRange(t.range) - lineEnd), line: l1))
                }
            }
        }
        var stack: [(unichar, Int)] = []
        let pairs: [unichar: unichar] = [125: 123, 93: 91, 41: 40]   // } ] )
        for i in 0..<ns.length where !skip.contains(i) {
            let c = ns.character(at: i)
            if c == 123 || c == 91 || c == 40 {
                stack.append((c, i))
            } else if let open = pairs[c] {
                guard let idx = stack.lastIndex(where: { $0.0 == open }) else { continue }
                let (_, start) = stack[idx]
                stack.removeSubrange(idx...)
                let l1 = index.line(for: start), l2 = index.line(for: i)
                if l2 > l1 { folds.append(FoldRange(range: NSRange(location: start + 1, length: i - start - 1), line: l1)) }
            }
        }
        return folds
    }

    // MARK: Indentation

    static func indentFolds(_ text: String, _ index: LineIndex) -> [FoldRange] {
        let ns = text as NSString
        var indents: [Int?] = []   // nil for blank lines
        for l in 0..<index.lineCount {
            let s = ns.substring(with: index.range(ofLine: l))
            if s.trimmingCharacters(in: .whitespaces).isEmpty { indents.append(nil); continue }
            var w = 0
            for ch in s { if ch == " " { w += 1 } else if ch == "\t" { w += 4 } else { break } }
            indents.append(w)
        }
        var folds: [FoldRange] = []
        for l in 0..<indents.count {
            guard let base = indents[l] else { continue }
            var last = l
            var k = l + 1
            while k < indents.count {
                if let w = indents[k] {
                    if w <= base { break }
                    last = k
                }
                k += 1
            }
            if last > l {
                let start = NSMaxRange(index.range(ofLine: l))
                let end = NSMaxRange(index.range(ofLine: last))
                folds.append(FoldRange(range: NSRange(location: start, length: end - start), line: l))
            }
        }
        return folds
    }

    // MARK: Markdown headings

    static func headingFolds(_ text: String, _ index: LineIndex) -> [FoldRange] {
        let ns = text as NSString
        var headings: [(line: Int, level: Int)] = []
        var inFence = false
        for l in 0..<index.lineCount {
            let s = ns.substring(with: index.range(ofLine: l))
            if s.hasPrefix("```") || s.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, s.hasPrefix("#") else { continue }
            let level = s.prefix { $0 == "#" }.count
            if level <= 6, s.dropFirst(level).first == " " { headings.append((l, level)) }
        }
        var folds: [FoldRange] = []
        for (i, h) in headings.enumerated() {
            var endLine = index.lineCount - 1
            if let next = headings[(i + 1)...].first(where: { $0.level <= h.level }) { endLine = next.line - 1 }
            while endLine > h.line, ns.substring(with: index.range(ofLine: endLine)).trimmingCharacters(in: .whitespaces).isEmpty { endLine -= 1 }
            if endLine > h.line {
                let start = NSMaxRange(index.range(ofLine: h.line))
                folds.append(FoldRange(range: NSRange(location: start, length: NSMaxRange(index.range(ofLine: endLine)) - start), line: h.line))
            }
        }
        return folds
    }

    // MARK: HTML / XML elements

    static let tag = try! NSRegularExpression(pattern: #"<(/?)([A-Za-z][\w:.-]*)(?:[^<>"']|"[^"]*"|'[^']*')*?(/?)>"#)
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

    static func tagFolds(_ text: String, _ index: LineIndex, language: Language) -> [FoldRange] {
        let ns = text as NSString
        var folds: [FoldRange] = []
        var stack: [(String, Int)] = []   // name, index after the open tag
        let isHTML = language.name == "HTML"
        // Comments fold as blocks.
        let comment = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->")
        var skip = IndexSet()
        for m in comment.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            skip.insert(integersIn: m.range.location..<NSMaxRange(m.range))
            let l1 = index.line(for: m.range.location), l2 = index.line(for: NSMaxRange(m.range) - 1)
            if l2 > l1 { folds.append(FoldRange(range: NSRange(location: m.range.location + 4, length: m.range.length - 7), line: l1)) }
        }
        for m in tag.matches(in: text, range: NSRange(location: 0, length: ns.length)) where !skip.contains(m.range.location) {
            let closing = m.range(at: 1).length > 0
            let selfClosing = m.range(at: 3).length > 0
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            if selfClosing || (isHTML && voidElements.contains(name)) { continue }
            if !closing {
                stack.append((name, NSMaxRange(m.range)))
            } else if let idx = stack.lastIndex(where: { $0.0 == name }) {
                let start = stack[idx].1
                stack.removeSubrange(idx...)
                let l1 = index.line(for: start - 1), l2 = index.line(for: m.range.location)
                if l2 > l1 { folds.append(FoldRange(range: NSRange(location: start, length: m.range.location - start), line: l1)) }
            }
        }
        return folds
    }
}
