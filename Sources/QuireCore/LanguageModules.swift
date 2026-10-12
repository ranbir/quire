import Foundation

/// JSON form of a language definition. Drop `*.json` files into the
/// Language Modules folder to add languages or override built-in ones.
///
///     {
///       "name": "Lua",
///       "extensions": ["lua"],
///       "lineComment": "--",
///       "blockComment": ["--[[", "]]"],
///       "keywords": ["and", "break", "do", ...],
///       "rules": [
///         { "pattern": "--\\[\\[[\\s\\S]*?(?:\\]\\]|\\z)", "kind": "comment" },
///         { "pattern": "--.*", "kind": "comment" },
///         { "pattern": "\"(?:\\\\.|[^\"\\\\\\n])*\"?", "kind": "string" }
///       ],
///       "symbolPatterns": ["^[ \\t]*(?:local[ \\t]+)?function[ \\t]+([\\w.:]+)"]
///     }
///
/// Rule kinds: keyword, type, string, comment, number, preprocessor, tag,
/// attribute, variable, heading, emphasis, link.
public struct LanguageModule: Codable, Equatable {
    public struct RuleSpec: Codable, Equatable {
        public var pattern: String
        public var kind: String
        public var inner: [RuleSpec]?
    }

    public var name: String
    public var extensions: [String]
    public var filenames: [String]?
    public var shebangs: [String]?
    public var rules: [RuleSpec]?
    public var keywords: [String]?
    public var types: [String]?
    public var caseInsensitiveKeywords: Bool?
    public var capitalizedAreTypes: Bool?
    public var highlightNumbers: Bool?
    public var lineComment: String?
    public var blockComment: [String]?
    public var symbolPatterns: [String]?
    public var indentAfter: String?

    public struct InvalidModule: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public func language() throws -> Language {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw InvalidModule(message: "Missing \"name\"") }
        func convert(_ specs: [RuleSpec]) throws -> [Rule] {
            try specs.map { spec in
                guard let kind = TokenKind(rawValue: spec.kind) else {
                    throw InvalidModule(message: "\(name): unknown rule kind “\(spec.kind)”")
                }
                do { _ = try NSRegularExpression(pattern: spec.pattern) } catch {
                    throw InvalidModule(message: "\(name): invalid pattern “\(spec.pattern)”")
                }
                return Rule(spec.pattern, kind, inner: try spec.inner.map(convert))
            }
        }
        var l = Language(name: name, extensions: extensions.map { $0.lowercased() })
        l.filenames = filenames ?? []
        l.shebangs = shebangs ?? []
        l.rules = try convert(rules ?? [])
        l.keywords = Set(keywords ?? [])
        if caseInsensitiveKeywords == true { l.keywords = Set(l.keywords.map { $0.lowercased() }) }
        l.types = Set(types ?? [])
        l.caseInsensitiveKeywords = caseInsensitiveKeywords ?? false
        l.capitalizedAreTypes = capitalizedAreTypes ?? false
        l.highlightNumbers = highlightNumbers ?? true
        l.lineComment = lineComment
        if let b = blockComment {
            guard b.count == 2 else { throw InvalidModule(message: "\(name): blockComment must be [open, close]") }
            l.blockComment = (b[0], b[1])
        }
        for p in symbolPatterns ?? [] {
            do { _ = try NSRegularExpression(pattern: p) } catch {
                throw InvalidModule(message: "\(name): invalid symbol pattern “\(p)”")
            }
        }
        l.symbolPatterns = symbolPatterns ?? []
        if let ia = indentAfter { l.indentAfter = Set(ia) }
        return l
    }

    public init(language l: Language) {
        func spec(_ r: Rule) -> RuleSpec { RuleSpec(pattern: r.pattern, kind: r.kind.rawValue, inner: r.inner?.map(spec)) }
        name = l.name
        extensions = l.extensions
        filenames = l.filenames.isEmpty ? nil : l.filenames
        shebangs = l.shebangs.isEmpty ? nil : l.shebangs
        rules = l.rules.map(spec)
        keywords = l.keywords.sorted()
        types = l.types.isEmpty ? nil : l.types.sorted()
        caseInsensitiveKeywords = l.caseInsensitiveKeywords ? true : nil
        capitalizedAreTypes = l.capitalizedAreTypes ? true : nil
        highlightNumbers = l.highlightNumbers ? nil : false
        lineComment = l.lineComment
        blockComment = l.blockComment.map { [$0.0, $0.1] }
        symbolPatterns = l.symbolPatterns.isEmpty ? nil : l.symbolPatterns
        indentAfter = String(l.indentAfter.sorted())
    }

    public static func decode(_ data: Data) throws -> LanguageModule {
        try JSONDecoder().decode(LanguageModule.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

extension Languages {
    /// Loads every `*.json` module in `folder` into `Languages.modules`.
    /// Returns a message for each file that failed to load.
    @discardableResult
    public static func loadModules(from folder: URL) -> [String] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var loaded: [Language] = []
        var errors: [String] = []
        for f in files {
            do {
                let lang = try LanguageModule.decode(try Data(contentsOf: f)).language()
                loaded.removeAll { $0.name == lang.name }
                loaded.append(lang)
            } catch let e as DecodingError {
                errors.append("\(f.lastPathComponent): \(describe(e))")
            } catch {
                errors.append("\(f.lastPathComponent): \(error.localizedDescription)")
            }
        }
        modules = loaded
        return errors
    }

    static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, _): return "missing key “\(k.stringValue)”"
        case .typeMismatch(_, let c), .valueNotFound(_, let c):
            return "wrong type at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let c): return c.debugDescription
        @unknown default: return "\(e)"
        }
    }
}
