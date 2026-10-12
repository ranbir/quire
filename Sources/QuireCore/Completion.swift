import Foundation

public enum Completion {
    static let word = try! NSRegularExpression(pattern: #"[A-Za-z_$][A-Za-z0-9_$]*"#)

    /// Ranked completions for `prefix`: words from the document (by frequency),
    /// the language's keywords and types, and any `extra` names (clippings).
    public static func candidates(prefix: String, text: String, language: Language,
                                  extra: [String] = [], limit: Int = 60) -> [String] {
        guard !prefix.isEmpty else { return [] }
        var freq: [String: Int] = [:]
        let ns = text as NSString
        word.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.range.length >= 3 else { return }
            freq[ns.substring(with: m.range), default: 0] += 1
        }
        // The word being typed counts once; don't let it promote itself.
        if let n = freq[prefix] { freq[prefix] = n - 1 }
        for w in language.keywords.union(language.types) { freq[w, default: 0] += 1 }
        for w in extra { freq[w, default: 0] += 1 }

        let lower = prefix.lowercased()
        let matches = freq.filter { word, count in
            count > 0 && word != prefix && word.count > prefix.count && word.lowercased().hasPrefix(lower)
        }
        return matches.keys.sorted { a, b in
            let ea = a.hasPrefix(prefix), eb = b.hasPrefix(prefix)
            if ea != eb { return ea }
            let fa = matches[a]!, fb = matches[b]!
            if fa != fb { return fa > fb }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }.prefix(limit).map { $0 }
    }
}

public struct ClippingContext {
    public var selection = ""
    public var indent = ""
    public var fileName = ""
    public var clipboard = ""
    public var date = Date()
    public init(selection: String = "", indent: String = "", fileName: String = "", clipboard: String = "", date: Date = Date()) {
        self.selection = selection; self.indent = indent; self.fileName = fileName; self.clipboard = clipboard; self.date = date
    }
}

/// Clippings are text snippets with substitution tokens:
///   #SELECTION#  the selected text      #INSERTION#  where the caret ends up
///   #CLIPBOARD#  clipboard contents     #DATE# #TIME# #FILENAME# #BASENAME#
///   <#name#>     placeholder; Next Placeholder (⌃/) jumps between them
public enum Clippings {
    public static let placeholder = try! NSRegularExpression(pattern: "<#[^#\\n]*#>")

    public static func expand(_ template: String, context c: ClippingContext) -> (text: String, selection: NSRange?) {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        let tf = DateFormatter(); tf.dateStyle = .none; tf.timeStyle = .short
        var t = TextCodec.normalizeLineEndings(template)
        if t.hasSuffix("\n") && !t.dropLast().contains("\n") {
            t.removeLast()   // single-line clipping files usually end with a stray newline
        }
        let subs: [(String, String)] = [
            ("#SELECTION#", c.selection), ("#CLIPBOARD#", c.clipboard),
            ("#DATE#", df.string(from: c.date)), ("#TIME#", tf.string(from: c.date)),
            ("#FILENAME#", c.fileName), ("#BASENAME#", (c.fileName as NSString).deletingPathExtension),
        ]
        for (k, v) in subs { t = t.replacingOccurrences(of: k, with: v) }

        // Re-indent continuation lines to the insertion point's indentation.
        if !c.indent.isEmpty {
            t = t.components(separatedBy: "\n").enumerated()
                .map { i, l in i == 0 || l.isEmpty ? l : c.indent + l }.joined(separator: "\n")
        }

        let ns = t as NSString
        let ins = ns.range(of: "#INSERTION#")
        if ins.location != NSNotFound {
            return (ns.replacingCharacters(in: ins, with: ""), NSRange(location: ins.location, length: 0))
        }
        if let m = placeholder.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
            return (t, m.range)
        }
        return (t, nil)
    }

    /// The next `<#placeholder#>` at or after `location`, wrapping to the start.
    public static func nextPlaceholder(in text: String, after location: Int) -> NSRange? {
        let len = (text as NSString).length
        let start = min(location, len)
        return placeholder.firstMatch(in: text, range: NSRange(location: start, length: len - start))?.range
            ?? placeholder.firstMatch(in: text, range: NSRange(location: 0, length: len))?.range
    }

    public static func previousPlaceholder(in text: String, before location: Int) -> NSRange? {
        let len = (text as NSString).length
        let all = placeholder.matches(in: text, range: NSRange(location: 0, length: len)).map(\.range)
        return all.last { NSMaxRange($0) <= location } ?? all.last
    }
}
