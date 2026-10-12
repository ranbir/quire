import Foundation

public struct Token: Equatable {
    public let range: NSRange
    public let kind: TokenKind
}

/// Regex-driven tokenizer. All of a language's rules are compiled into one
/// alternation so that scanning is a single left-to-right pass: whichever
/// construct starts first wins, which keeps "//" inside a string from being
/// treated as a comment.
public final class Tokenizer {
    enum Slot {
        case rule(TokenKind, Tokenizer?)
        case number
        case identifier
    }

    let language: Language
    let regex: NSRegularExpression?
    let slots: [(group: Int, slot: Slot)]

    static let numberPattern = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#
    static let identifierPattern = #"[A-Za-z_][A-Za-z0-9_]*[?!]?"#

    public convenience init(language: Language) {
        self.init(language: language, rules: language.rules, includeWords: true)
    }

    init(language: Language, rules: [Rule], includeWords: Bool) {
        self.language = language
        var parts: [String] = []
        var slots: [(Int, Slot)] = []
        var group = 1
        func add(_ pattern: String, _ slot: Slot) {
            guard let r = try? NSRegularExpression(pattern: pattern) else { return }
            parts.append("(\(pattern))")
            slots.append((group, slot))
            group += 1 + r.numberOfCaptureGroups
        }
        for rule in rules {
            let inner = rule.inner.map { Tokenizer(language: language, rules: $0, includeWords: false) }
            add(rule.pattern, .rule(rule.kind, inner))
        }
        if includeWords {
            if language.highlightNumbers { add(Self.numberPattern, .number) }
            if !language.keywords.isEmpty || !language.types.isEmpty || language.capitalizedAreTypes {
                add(Self.identifierPattern, .identifier)
            }
        }
        self.slots = slots
        self.regex = parts.isEmpty ? nil : try? NSRegularExpression(pattern: parts.joined(separator: "|"), options: [.anchorsMatchLines])
    }

    public func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        tokenize(text, range: NSRange(location: 0, length: (text as NSString).length), into: &tokens)
        return tokens
    }

    func tokenize(_ text: String, range: NSRange, into tokens: inout [Token]) {
        guard let regex else { return }
        let ns = text as NSString
        let lang = language
        regex.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m else { return }
            for (group, slot) in slots {
                let r = m.range(at: group)
                guard r.location != NSNotFound else { continue }
                guard r.length > 0 else { break }
                switch slot {
                case .rule(let kind, let inner):
                    tokens.append(Token(range: r, kind: kind))
                    inner?.tokenize(text, range: r, into: &tokens)
                case .number:
                    tokens.append(Token(range: r, kind: .number))
                case .identifier:
                    var word = ns.substring(with: r)
                    if lang.caseInsensitiveKeywords { word = word.lowercased() }
                    if lang.keywords.contains(word) {
                        tokens.append(Token(range: r, kind: .keyword))
                    } else if lang.types.contains(word) {
                        tokens.append(Token(range: r, kind: .type))
                    } else if lang.capitalizedAreTypes, let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) {
                        tokens.append(Token(range: r, kind: .type))
                    }
                }
                break
            }
        }
    }
}

public struct Symbol: Equatable {
    public let name: String
    public let location: Int
    public let line: Int
}

public enum SymbolScanner {
    public static func symbols(in text: String, language: Language) -> [Symbol] {
        if language.name == "Markdown" {
            // Parsed headings, indented by level.
            let index = LineIndex(text)
            return MarkdownDocument(text).headings.map { h in
                Symbol(name: String(repeating: "  ", count: h.level - 1) + h.text, location: h.range.location, line: index.line(for: h.range.location) + 1)
            }
        }
        guard !language.symbolPatterns.isEmpty else { return [] }
        let ns = text as NSString
        let index = LineIndex(text)
        var found: [Int: Symbol] = [:]
        for p in language.symbolPatterns {
            guard let r = try? NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) else { continue }
            r.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges > 1 else { return }
                let g = m.range(at: 1)
                guard g.location != NSNotFound, g.length > 0 else { return }
                let name = ns.substring(with: g).trimmingCharacters(in: .whitespaces)
                if language.keywords.contains(name) { return }
                let line = index.line(for: g.location)
                if found[line] == nil {
                    found[line] = Symbol(name: name, location: g.location, line: line + 1)
                }
            }
        }
        return found.values.sorted { $0.location < $1.location }
    }
}
