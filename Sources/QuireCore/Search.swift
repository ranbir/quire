import Foundation

public struct SearchOptions: Equatable {
    public var pattern: String
    public var caseSensitive = false
    public var wholeWord = false
    /// Treat `pattern` as a regular expression ("grep" mode).
    public var grep = false
    public var wrapAround = true

    public init(pattern: String, caseSensitive: Bool = false, wholeWord: Bool = false, grep: Bool = false, wrapAround: Bool = true) {
        self.pattern = pattern; self.caseSensitive = caseSensitive; self.wholeWord = wholeWord
        self.grep = grep; self.wrapAround = wrapAround
    }
}

public struct SearchHit: Equatable {
    public let url: URL?
    /// 1-based line number.
    public let line: Int
    /// UTF-16 offset of the match within its line.
    public let column: Int
    public let length: Int
    public let lineText: String

    public init(url: URL?, line: Int, column: Int, length: Int, lineText: String) {
        self.url = url; self.line = line; self.column = column; self.length = length; self.lineText = lineText
    }
}

public enum SearchEngine {

    public static func regex(for o: SearchOptions) throws -> NSRegularExpression {
        var p = o.grep ? o.pattern : NSRegularExpression.escapedPattern(for: o.pattern)
        if o.wholeWord { p = "\\b(?:\(p))\\b" }
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if !o.caseSensitive { opts.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: p, options: opts)
    }

    /// Converts a grep-style replacement (\1, \n, \t, &) into an
    /// NSRegularExpression template ($1, literal newline, …). In literal
    /// mode only escapes the template metacharacters.
    public static func replacementTemplate(_ r: String, grep: Bool) -> String {
        guard grep else { return NSRegularExpression.escapedTemplate(for: r) }
        var out = ""
        var it = r.makeIterator()
        while let ch = it.next() {
            switch ch {
            case "\\":
                guard let n = it.next() else { out += "\\\\"; break }
                switch n {
                case "0"..."9": out += "$\(n)"
                case "n", "r": out += "\n"
                case "t": out += "\t"
                case "&": out += "&"
                case "$": out += "\\$"
                case "\\": out += "\\\\"
                default: out += "\\\\"; out.append(n)
                }
            case "&": out += "$0"
            case "$": out += "\\$"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Finds the next match after (or before, when `backwards`) the selection.
    public static func find(in text: String, regex: NSRegularExpression, from selection: NSRange,
                            backwards: Bool, wrap: Bool) -> NSRange? {
        let length = (text as NSString).length
        if backwards {
            func last(in range: NSRange) -> NSRange? {
                var hit: NSRange?
                regex.enumerateMatches(in: text, range: range) { m, _, _ in if let m, m.range.length > 0 { hit = m.range } }
                return hit
            }
            if let r = last(in: NSRange(location: 0, length: selection.location)) { return r }
            return wrap ? last(in: NSRange(location: 0, length: length)) : nil
        }
        let start = NSMaxRange(selection)
        func first(in range: NSRange) -> NSRange? {
            var hit: NSRange?
            regex.enumerateMatches(in: text, range: range) { m, _, stop in
                if let m, m.range.length > 0 { hit = m.range; stop.pointee = true }
            }
            return hit
        }
        if start <= length, let r = first(in: NSRange(location: start, length: length - start)) { return r }
        return wrap ? first(in: NSRange(location: 0, length: length)) : nil
    }

    /// All matches in `text`, reported per line.
    public static func findAll(in text: String, regex: NSRegularExpression, url: URL? = nil, range: NSRange? = nil) -> [SearchHit] {
        let ns = text as NSString
        let index = LineIndex(text)
        var hits: [SearchHit] = []
        regex.enumerateMatches(in: text, range: range ?? NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.range.length > 0 else { return }
            let line = index.line(for: m.range.location)
            let lineRange = index.range(ofLine: line)
            var lineText = ns.substring(with: lineRange)
            if lineText.count > 400 { lineText = String(lineText.prefix(400)) + "…" }
            hits.append(SearchHit(url: url, line: line + 1, column: m.range.location - lineRange.location,
                                  length: m.range.length, lineText: lineText))
        }
        return hits
    }

    static let skippedDirectories: Set<String> = [".git", ".svn", ".hg", "node_modules", ".build", "DerivedData", "Pods", ".venv", "__pycache__"]

    /// Matches a filename against a list of globs like "*.swift, *.m".
    public static func filenameMatches(_ name: String, globs: String) -> Bool {
        let patterns = globs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if patterns.isEmpty { return true }
        return patterns.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }

    /// Searches every text file under `folder`. `progress` is called with each
    /// file scanned; return false from it to cancel.
    public static func searchFolder(_ folder: URL, options: SearchOptions, fileFilter: String = "",
                                    includeHidden: Bool = false, maxFileSize: Int = 20_000_000,
                                    progress: ((URL) -> Bool)? = nil) throws -> [SearchHit] {
        let regex = try regex(for: options)
        var hits: [SearchHit] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isPackageKey]
        var enumOpts: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { enumOpts.insert(.skipsHiddenFiles) }
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: enumOpts) else { return [] }
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) || v?.isPackage == true { e.skipDescendants() }
                continue
            }
            guard v?.isRegularFile == true, (v?.fileSize ?? 0) <= maxFileSize else { continue }
            guard filenameMatches(url.lastPathComponent, globs: fileFilter) else { continue }
            if let progress, !progress(url) { break }
            guard let data = try? Data(contentsOf: url), !TextCodec.looksBinary(data) else { continue }
            let text = TextCodec.decode(data).text
            hits += findAll(in: text, regex: regex, url: url)
        }
        return hits
    }
}
