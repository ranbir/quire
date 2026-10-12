import Foundation

/// Pure text-processing commands behind the Text menu. Every function takes
/// LF-delimited text and returns the transformed text.
public enum TextTransforms {

    // MARK: Line helpers

    /// Splits into lines; a trailing newline does not produce an extra empty line.
    static func splitLines(_ s: String) -> (lines: [String], trailingNewline: Bool) {
        let trailing = s.hasSuffix("\n")
        var body = s
        if trailing { body.removeLast() }
        return (body.components(separatedBy: "\n"), trailing)
    }

    static func joinLines(_ lines: [String], trailingNewline: Bool) -> String {
        lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    public static func mapLines(_ s: String, _ f: ([String]) -> [String]) -> String {
        let (lines, trailing) = splitLines(s)
        return joinLines(f(lines), trailingNewline: trailing)
    }

    static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    // MARK: Case

    public static func upperCase(_ s: String) -> String { s.uppercased() }
    public static func lowerCase(_ s: String) -> String { s.lowercased() }
    public static func capitalizeWords(_ s: String) -> String { s.capitalized }

    static let smallWords: Set<String> = ["a", "an", "the", "and", "but", "or", "for", "nor", "on", "at",
                                          "to", "from", "by", "of", "in", "as", "vs", "via", "with"]

    public static func titleCase(_ s: String) -> String {
        mapLines(s) { lines in
            lines.map { line in
                let words = line.components(separatedBy: " ")
                let lastIndex = words.lastIndex { !$0.isEmpty } ?? 0
                return words.enumerated().map { i, word in
                    guard let first = word.first else { return word }
                    let lower = word.lowercased()
                    let isEdge = i == 0 || i == lastIndex
                    if !isEdge && smallWords.contains(lower) { return lower }
                    // Leave words with interior capitals (iPhone, macOS) alone.
                    if word.dropFirst().contains(where: { $0.isUppercase }) { return word }
                    return first.uppercased() + word.dropFirst()
                }.joined(separator: " ")
            }
        }
    }

    public static func capitalizeLines(_ s: String) -> String {
        mapLines(s) { $0.map { line in
            let ws = leadingWhitespace(line)
            let rest = line.dropFirst(ws.count)
            guard let f = rest.first else { return line }
            return ws + f.uppercased() + rest.dropFirst()
        } }
    }

    public static func capitalizeSentences(_ s: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in s {
            if capitalizeNext && ch.isLetter {
                out += ch.uppercased(); capitalizeNext = false
            } else {
                out.append(ch)
                if ch == "." || ch == "!" || ch == "?" || ch == "\n" { capitalizeNext = true }
                else if !ch.isWhitespace && !ch.isPunctuation { capitalizeNext = false }
            }
        }
        return out
    }

    // MARK: Sorting & duplicates

    public struct SortOptions {
        public var descending = false
        public var numeric = false
        public var caseInsensitive = true
        public init(descending: Bool = false, numeric: Bool = false, caseInsensitive: Bool = true) {
            self.descending = descending; self.numeric = numeric; self.caseInsensitive = caseInsensitive
        }
    }

    public static func sortLines(_ s: String, _ o: SortOptions = SortOptions()) -> String {
        mapLines(s) { lines in
            var opts: String.CompareOptions = []
            if o.numeric { opts.insert(.numeric) }
            if o.caseInsensitive { opts.insert(.caseInsensitive) }
            let sorted = lines.sorted { $0.compare($1, options: opts) == .orderedAscending }
            return o.descending ? sorted.reversed() : sorted
        }
    }

    public static func removeDuplicateLines(_ s: String) -> String {
        mapLines(s) { lines in
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }
        }
    }

    public static func reverseLines(_ s: String) -> String { mapLines(s) { $0.reversed() } }

    /// Keeps (or removes) lines matching `regex`.
    public static func processLines(_ s: String, matching regex: NSRegularExpression, keep: Bool) -> String {
        mapLines(s) { lines in
            lines.filter { line in
                let hit = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
                return hit == keep
            }
        }
    }

    // MARK: Prefix / numbering

    public static func prefixSuffix(_ s: String, prefix: String, suffix: String) -> String {
        mapLines(s) { $0.map { prefix + $0 + suffix } }
    }

    public static func addLineNumbers(_ s: String, start: Int = 1, separator: String = " ") -> String {
        mapLines(s) { lines in
            let width = String(start + lines.count - 1).count
            return lines.enumerated().map { i, line in
                let n = String(start + i)
                return String(repeating: " ", count: width - n.count) + n + separator + line
            }
        }
    }

    static let lineNumberPrefix = try! NSRegularExpression(pattern: #"^[ \t]*\d+[:.)]?[ \t]?"#)

    public static func removeLineNumbers(_ s: String) -> String {
        mapLines(s) { $0.map { line in
            let ns = line as NSString
            return lineNumberPrefix.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        } }
    }

    // MARK: Whitespace

    public static func stripTrailingWhitespace(_ s: String) -> String {
        mapLines(s) { $0.map { line in
            var l = Substring(line)
            while let last = l.last, last == " " || last == "\t" { l = l.dropLast() }
            return String(l)
        } }
    }

    /// Removes invisible "gremlins": control characters (other than tab/newline),
    /// zero-width characters and BOMs; turns non-breaking spaces into spaces.
    public static func zapGremlins(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x09, 0x0A: scalars.append(u)
            case 0x0D: scalars.append("\n")
            case 0x00...0x1F, 0x7F, 0x80...0x9F: continue
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: continue
            case 0x00A0, 0x202F: scalars.append(" ")
            default: scalars.append(u)
            }
        }
        return String(scalars)
    }

    public static func detab(_ s: String, tabWidth: Int) -> String {
        mapLines(s) { $0.map { line in
            guard line.contains("\t") else { return line }
            var out = ""
            var col = 0
            for ch in line {
                if ch == "\t" {
                    let n = tabWidth - (col % tabWidth)
                    out += String(repeating: " ", count: n); col += n
                } else {
                    out.append(ch); col += 1
                }
            }
            return out
        } }
    }

    /// Converts leading runs of spaces to tabs.
    public static func entab(_ s: String, tabWidth: Int) -> String {
        mapLines(s) { $0.map { line in
            let ws = leadingWhitespace(line)
            var col = 0
            for ch in ws { col = ch == "\t" ? (col / tabWidth + 1) * tabWidth : col + 1 }
            let newWS = String(repeating: "\t", count: col / tabWidth) + String(repeating: " ", count: col % tabWidth)
            return newWS + line.dropFirst(ws.count)
        } }
    }

    public static func shiftRight(_ s: String, unit: String) -> String {
        mapLines(s) { $0.map { $0.isEmpty ? $0 : unit + $0 } }
    }

    public static func shiftLeft(_ s: String, tabWidth: Int) -> String {
        mapLines(s) { $0.map { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix(tabWidth).prefix { $0 == " " }.count
            return String(line.dropFirst(spaces))
        } }
    }

    // MARK: Wrapping

    static func paragraphs(_ lines: [String]) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current); current = [] }
                result.append([])   // blank line marker
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func hardWrap(_ s: String, width: Int) -> String {
        mapLines(s) { lines in
            var out: [String] = []
            for para in paragraphs(lines) {
                if para.isEmpty { out.append(""); continue }
                let indent = leadingWhitespace(para[0])
                let words = para.joined(separator: " ").split(whereSeparator: { $0 == " " || $0 == "\t" })
                var line = indent
                for w in words {
                    if line.count > indent.count && line.count + 1 + w.count > width {
                        out.append(line); line = indent
                    }
                    line += (line.count > indent.count ? " " : "") + w
                }
                out.append(line)
            }
            return out
        }
    }

    /// Joins the lines of each paragraph into one line, keeping blank lines between paragraphs.
    public static func removeLineBreaks(_ s: String) -> String {
        mapLines(s) { lines in
            paragraphs(lines).map { para in
                para.enumerated().map { i, l in i == 0 ? l : l.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
        }
    }

    // MARK: Comments

    public static func toggleLineComment(_ s: String, prefix: String) -> String {
        mapLines(s) { lines in
            let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !nonBlank.isEmpty else { return lines }
            let allCommented = nonBlank.allSatisfy { $0.dropFirst(leadingWhitespace($0).count).hasPrefix(prefix) }
            if allCommented {
                return lines.map { line in
                    let ws = leadingWhitespace(line)
                    var rest = line.dropFirst(ws.count)
                    guard rest.hasPrefix(prefix) else { return line }
                    rest = rest.dropFirst(prefix.count)
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    return ws + rest
                }
            }
            let minIndent = nonBlank.map { leadingWhitespace($0).count }.min() ?? 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                return line.prefix(minIndent) + prefix + " " + line.dropFirst(minIndent)
            }
        }
    }

    public static func toggleBlockComment(_ s: String, open: String, close: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(open) && trimmed.hasSuffix(close) && trimmed.count >= open.count + close.count {
            var inner = trimmed.dropFirst(open.count).dropLast(close.count)
            if inner.hasPrefix(" ") { inner = inner.dropFirst() }
            if inner.hasSuffix(" ") { inner = inner.dropLast() }
            return s.replacingOccurrences(of: trimmed, with: String(inner))
        }
        return open + " " + s + " " + close
    }

    // MARK: Quotes, JSON, stats

    public static func straightenQuotes(_ s: String) -> String {
        var out = s
        for (from, to) in [("“", "\""), ("”", "\""), ("„", "\""), ("‘", "'"), ("’", "'"), ("‚", "'")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }

    public static func educateQuotes(_ s: String) -> String {
        var out = ""
        var prev: Character = " "
        for ch in s {
            let opening = prev.isWhitespace || "([{<—–-".contains(prev)
            switch ch {
            case "\"": out += opening ? "“" : "”"
            case "'": out += opening ? "‘" : "’"
            default: out.append(ch)
            }
            prev = ch
        }
        return out
    }

    public static func formatJSON(_ s: String, indent: Int = 2) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed])
        var out = String(decoding: data, as: UTF8.self)
        if indent != 2 {
            out = mapLines(out) { $0.map { line in
                let n = line.prefix { $0 == " " }.count
                return String(repeating: " ", count: n / 2 * indent) + line.dropFirst(n)
            } }
        }
        return out + (s.hasSuffix("\n") ? "\n" : "")
    }

    public struct Statistics: Equatable {
        public let characters: Int
        public let words: Int
        public let lines: Int
    }

    public static func statistics(_ s: String) -> Statistics {
        var words = 0
        s.enumerateSubstrings(in: s.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let lines = s.isEmpty ? 0 : splitLines(s).lines.count
        return Statistics(characters: s.count, words: words, lines: lines)
    }
}
