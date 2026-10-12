import Foundation

public enum TokenKind: String, CaseIterable {
    case keyword, type, string, comment, number, preprocessor, tag, attribute, variable, heading, emphasis, link
}

public struct Rule {
    public let pattern: String
    public let kind: TokenKind
    /// Rules applied inside a match (e.g. attributes inside an HTML tag).
    public let inner: [Rule]?
    public init(_ pattern: String, _ kind: TokenKind, inner: [Rule]? = nil) {
        self.pattern = pattern; self.kind = kind; self.inner = inner
    }
}

public struct Language {
    public let name: String
    public let extensions: [String]
    public var filenames: [String] = []
    public var shebangs: [String] = []
    /// Highest-priority first. Patterns are tried as one alternation, so the
    /// earliest match in the text wins and ties go to the earlier rule.
    public var rules: [Rule] = []
    public var keywords: Set<String> = []
    public var types: Set<String> = []
    public var caseInsensitiveKeywords = false
    public var capitalizedAreTypes = false
    public var highlightNumbers = true
    public var lineComment: String?
    public var blockComment: (String, String)?
    public var symbolPatterns: [String] = []
    /// Characters after which a newline adds one indent level.
    public var indentAfter: Set<Character> = ["{", "[", "("]

    public init(name: String, extensions: [String]) {
        self.name = name; self.extensions = extensions
    }
}

// MARK: - Shared patterns

enum P {
    static let lineCommentSlash = Rule(#"//.*"#, .comment)
    static let blockComment = Rule(#"/\*[\s\S]*?(?:\*/|\z)"#, .comment)
    static let hashComment = Rule(#"#.*"#, .comment)
    static let dq = Rule(#""(?:\\.|[^"\\\n])*"?"#, .string)
    static let sq = Rule(#"'(?:\\.|[^'\\\n])*'?"#, .string)
    static let backtick = Rule(#"`(?:\\.|[^`\\])*`?"#, .string)
    static let tripleDQ = Rule(#""""[\s\S]*?(?:"""|\z)"#, .string)
    static let tripleSQ = Rule(#"'''[\s\S]*?(?:'''|\z)"#, .string)
    static let cStyle = [lineCommentSlash, blockComment]
}

func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

// MARK: - Built-in languages

public enum Languages {
    public static let plainText = Language(name: "Plain Text", extensions: ["txt", "text"])

    /// Languages compiled into the app.
    public static let builtIn: [Language] = {
        var list: [Language] = []

        var swift = Language(name: "Swift", extensions: ["swift"])
        swift.rules = P.cStyle + [P.tripleDQ, P.dq, Rule(#"[@#][A-Za-z_]\w*"#, .preprocessor)]
        swift.keywords = words("actor any as associatedtype async await break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in indirect infix init inout internal is lazy let mutating nil nonisolated nonmutating open operator optional override postfix precedencegroup prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws true try typealias unowned var weak where while willSet consuming borrowing package")
        swift.capitalizedAreTypes = true
        swift.lineComment = "//"; swift.blockComment = ("/*", "*/")
        swift.symbolPatterns = [#"^[ \t]*(?:[@\w]+(?:\([^)\n]*\))?[ \t]+)*(?:func|class|struct|enum|protocol|extension|actor|typealias)[ \t]+([A-Za-z_][\w.]*)"#]
        list.append(swift)

        let cKeywords = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false NULL _Bool"
        var c = Language(name: "C", extensions: ["c", "h"])
        c.rules = P.cStyle + [P.dq, P.sq, Rule(#"^[ \t]*#[ \t]*\w+"#, .preprocessor), Rule(#"<[\w./]+\.h>"#, .string)]
        c.keywords = words(cKeywords)
        c.types = words("size_t ssize_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE")
        c.lineComment = "//"; c.blockComment = ("/*", "*/")
        c.symbolPatterns = [#"^(?:[A-Za-z_][\w*&:<> \t]*[ \t*&])?([A-Za-z_][\w:~]*)[ \t]*\([^;\n]*$"#, #"^[ \t]*(?:typedef[ \t]+)?(?:struct|enum|union|class|namespace)[ \t]+(\w+)"#]
        list.append(c)

        var cpp = c
        cpp = Language(name: "C++", extensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "ipp"])
        cpp.rules = c.rules; cpp.lineComment = "//"; cpp.blockComment = ("/*", "*/"); cpp.symbolPatterns = c.symbolPatterns
        cpp.keywords = words(cKeywords + " alignas alignof and asm catch class constexpr consteval constinit concept co_await co_return co_yield decltype delete explicit export friend mutable namespace new noexcept not nullptr operator or override final private protected public requires static_assert template this thread_local throw try typeid typename using virtual xor")
        cpp.types = c.types.union(words("std string vector map set unique_ptr shared_ptr optional"))
        list.append(cpp)

        var objc = Language(name: "Objective-C", extensions: ["m", "mm"])
        objc.rules = P.cStyle + [Rule(#"@"(?:\\.|[^"\\\n])*"?"#, .string), P.dq, P.sq, Rule(#"^[ \t]*#[ \t]*\w+"#, .preprocessor), Rule(#"@\w+"#, .keyword)]
        objc.keywords = words(cKeywords + " id self super nil Nil YES NO instancetype nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull")
        objc.capitalizedAreTypes = true
        objc.lineComment = "//"; objc.blockComment = ("/*", "*/")
        objc.symbolPatterns = [#"^[ \t]*[-+][ \t]*\([^)]*\)[ \t]*(\w+)"#, #"^@(?:interface|implementation|protocol)[ \t]+(\w+)"#] + c.symbolPatterns
        list.append(objc)

        let jsKeywords = "async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield"
        var js = Language(name: "JavaScript", extensions: ["js", "mjs", "cjs", "jsx"])
        js.shebangs = ["node"]
        js.rules = P.cStyle + [P.dq, P.sq, P.backtick]
        js.keywords = words(jsKeywords)
        js.capitalizedAreTypes = true
        js.lineComment = "//"; js.blockComment = ("/*", "*/")
        js.symbolPatterns = [
            #"function[ \t]*\*?[ \t]*([A-Za-z_$][\w$]*)"#,
            #"^[ \t]*(?:export[ \t]+)?(?:default[ \t]+)?(?:abstract[ \t]+)?class[ \t]+([A-Za-z_$][\w$]*)"#,
            #"^[ \t]*(?:export[ \t]+)?(?:const|let|var)[ \t]+([A-Za-z_$][\w$]*)[ \t]*=[ \t]*(?:async[ \t]*)?(?:function|\([^)\n]*\)[ \t]*=>|[A-Za-z_$][\w$]*[ \t]*=>)"#,
            #"^[ \t]+(?:static[ \t]+)?(?:async[ \t]+)?([A-Za-z_$][\w$]*)[ \t]*\([^)\n]*\)[ \t]*\{"#,
        ]
        list.append(js)

        var ts = js
        ts = Language(name: "TypeScript", extensions: ["ts", "tsx", "mts", "cts"])
        ts.rules = js.rules; ts.lineComment = "//"; ts.blockComment = ("/*", "*/"); ts.capitalizedAreTypes = true
        ts.keywords = words(jsKeywords + " abstract as declare enum implements interface keyof namespace private protected public readonly type any boolean number string unknown never satisfies")
        ts.symbolPatterns = js.symbolPatterns + [#"^[ \t]*(?:export[ \t]+)?(?:interface|type|enum)[ \t]+([A-Za-z_$][\w$]*)"#]
        list.append(ts)

        var py = Language(name: "Python", extensions: ["py", "pyw", "pyi"])
        py.shebangs = ["python"]
        py.rules = [P.tripleDQ, P.tripleSQ, P.hashComment, P.dq, P.sq, Rule(#"^[ \t]*@[\w.]+"#, .preprocessor)]
        py.keywords = words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield match case self")
        py.types = words("int float str bool list dict set tuple bytes object type Exception")
        py.capitalizedAreTypes = true
        py.lineComment = "#"
        py.indentAfter = [":", "{", "[", "("]
        py.symbolPatterns = [#"^[ \t]*(?:async[ \t]+)?def[ \t]+(\w+)"#, #"^[ \t]*class[ \t]+(\w+)"#]
        list.append(py)

        var rb = Language(name: "Ruby", extensions: ["rb", "rake", "gemspec"])
        rb.filenames = ["Rakefile", "Gemfile", "Podfile", "Fastfile"]
        rb.shebangs = ["ruby"]
        rb.rules = [Rule(#"^=begin[\s\S]*?(?:^=end|\z)"#, .comment), P.hashComment, P.dq, P.sq, Rule(#"@@?\w+|\$\w+"#, .variable), Rule(#"(?<![:\w]):\w+[?!]?"#, .variable)]
        rb.keywords = words("alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer private protected public")
        rb.capitalizedAreTypes = true
        rb.lineComment = "#"
        rb.symbolPatterns = [#"^[ \t]*def[ \t]+([\w.?!=]+)"#, #"^[ \t]*(?:class|module)[ \t]+([\w:]+)"#]
        list.append(rb)

        var sh = Language(name: "Shell Script", extensions: ["sh", "bash", "zsh", "ksh", "command"])
        sh.filenames = [".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile"]
        sh.shebangs = ["sh", "bash", "zsh", "ksh", "dash"]
        sh.rules = [Rule(#"\$\{[^}\n]*\}|\$[\w#?@*!$-]"#, .variable), Rule(#"(?<![\w$])#.*"#, .comment), P.dq, Rule(#"'[^'\n]*'?"#, .string)]
        sh.keywords = words("if then else elif fi for while until do done case esac function in return local export readonly declare unset shift break continue exit source alias select time")
        sh.lineComment = "#"
        sh.symbolPatterns = [#"^[ \t]*(?:function[ \t]+)?([A-Za-z_][\w-]*)[ \t]*\(\)"#, #"^[ \t]*function[ \t]+([A-Za-z_][\w-]*)"#]
        list.append(sh)

        var go = Language(name: "Go", extensions: ["go"])
        go.rules = P.cStyle + [P.dq, P.backtick, P.sq]
        go.keywords = words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota")
        go.types = words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any")
        go.capitalizedAreTypes = false
        go.lineComment = "//"; go.blockComment = ("/*", "*/")
        go.symbolPatterns = [#"^func[ \t]+(?:\([^)]*\)[ \t]*)?(\w+)"#, #"^type[ \t]+(\w+)"#]
        list.append(go)

        var rust = Language(name: "Rust", extensions: ["rs"])
        rust.rules = P.cStyle + [P.dq, Rule(#"'(?:\\.|[^'\\\n])'"#, .string), Rule(#"'[A-Za-z_]\w*"#, .variable), Rule(#"#!?\[[^\]\n]*\]"#, .preprocessor), Rule(#"\b[A-Za-z_]\w*!"#, .preprocessor)]
        rust.keywords = words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while")
        rust.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
        rust.capitalizedAreTypes = true
        rust.lineComment = "//"; rust.blockComment = ("/*", "*/")
        rust.symbolPatterns = [#"^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?(?:async[ \t]+)?(?:unsafe[ \t]+)?(?:fn|struct|enum|trait|mod|type|union)[ \t]+(\w+)"#, #"^[ \t]*impl(?:<[^>]*>)?[ \t]+([\w:]+)"#]
        list.append(rust)

        var java = Language(name: "Java", extensions: ["java", "kt", "kts", "scala", "groovy", "gradle"])
        java.rules = P.cStyle + [P.tripleDQ, P.dq, P.sq, Rule(#"@\w+"#, .preprocessor)]
        java.keywords = words("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var record sealed permits yield fun val object when data companion override open internal lateinit")
        java.capitalizedAreTypes = true
        java.lineComment = "//"; java.blockComment = ("/*", "*/")
        java.symbolPatterns = [#"^[ \t]*(?:(?:public|private|protected|static|final|abstract|sealed|data|open|internal)[ \t]+)*(?:class|interface|enum|record|object)[ \t]+(\w+)"#,
                               #"^[ \t]*(?:(?:public|private|protected|static|final|abstract|synchronized|override)[ \t]+)+[\w<>\[\], ]+[ \t]+(\w+)[ \t]*\("#,
                               #"^[ \t]*(?:\w+[ \t]+)*fun[ \t]+(?:<[^>]*>[ \t]*)?(?:[\w.]+\.)?(\w+)"#]
        list.append(java)

        var php = Language(name: "PHP", extensions: ["php", "phtml"])
        php.shebangs = ["php"]
        php.rules = P.cStyle + [Rule(#"(?<![\w$])#.*"#, .comment), P.dq, P.sq, Rule(#"\$\w+"#, .variable), Rule(#"<\?(?:php|=)?|\?>"#, .preprocessor)]
        php.keywords = words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while yield true false null")
        php.caseInsensitiveKeywords = true
        php.lineComment = "//"; php.blockComment = ("/*", "*/")
        php.symbolPatterns = [#"function[ \t]+&?(\w+)"#, #"^[ \t]*(?:abstract[ \t]+|final[ \t]+)?(?:class|interface|trait|enum)[ \t]+(\w+)"#]
        list.append(php)

        var sql = Language(name: "SQL", extensions: ["sql"])
        sql.rules = [Rule(#"--.*"#, .comment), P.blockComment, Rule(#"'(?:''|[^'])*'?"#, .string), Rule(#""[^"\n]*"|`[^`\n]*`"#, .variable)]
        sql.keywords = words("add all alter and any as asc between by case cascade check column commit constraint create cross database default delete desc distinct drop else end exists foreign from full group having if in index inner insert into is join key left like limit not null offset on or order outer primary references replace returning right rollback select set table then transaction trigger truncate union unique update values view when where with begin over partition window")
        sql.types = words("int integer bigint smallint tinyint decimal numeric float real double char varchar text blob boolean date time timestamp datetime serial uuid json jsonb")
        sql.caseInsensitiveKeywords = true
        sql.lineComment = "--"; sql.blockComment = ("/*", "*/")
        sql.symbolPatterns = [#"(?i)^[ \t]*create[ \t]+(?:or[ \t]+replace[ \t]+)?(?:table|view|index|function|procedure|trigger)[ \t]+(?:if[ \t]+not[ \t]+exists[ \t]+)?([\w.\"`]+)"#]
        list.append(sql)

        let tagInner = [Rule(#"(?<=\s)[A-Za-z_:@][\w:.-]*"#, .attribute), P.dq, Rule(#"'[^'\n]*'"#, .string)]
        var html = Language(name: "HTML", extensions: ["html", "htm", "xhtml", "shtml", "vue", "svelte"])
        html.rules = [Rule(#"<!--[\s\S]*?(?:-->|\z)"#, .comment), Rule(#"<![A-Za-z][^>]*>"#, .preprocessor),
                      Rule(#"</?[A-Za-z][\w:.-]*(?:[^<>"']|"[^"]*"|'[^']*')*>?"#, .tag, inner: tagInner),
                      Rule(#"&#?\w+;"#, .variable)]
        html.highlightNumbers = false
        html.blockComment = ("<!--", "-->")
        html.indentAfter = []
        html.symbolPatterns = [#"<h[1-6][^>]*>([^<\n]+)"#, #"\bid="([^"]+)""#]
        list.append(html)

        var xml = Language(name: "XML", extensions: ["xml", "plist", "xsd", "xsl", "xslt", "svg", "rss", "atom", "storyboard", "xib", "csproj", "sdef"])
        xml.rules = [Rule(#"<!--[\s\S]*?(?:-->|\z)"#, .comment), Rule(#"<!\[CDATA\[[\s\S]*?(?:\]\]>|\z)"#, .string),
                     Rule(#"<\?[\s\S]*?(?:\?>|\z)"#, .preprocessor), Rule(#"<![A-Za-z][^>]*>"#, .preprocessor),
                     Rule(#"</?[A-Za-z_][\w:.-]*(?:[^<>"']|"[^"]*"|'[^']*')*>?"#, .tag, inner: tagInner),
                     Rule(#"&#?\w+;"#, .variable)]
        xml.highlightNumbers = false
        xml.blockComment = ("<!--", "-->")
        xml.indentAfter = []
        list.append(xml)

        var css = Language(name: "CSS", extensions: ["css", "scss", "sass", "less"])
        css.rules = [P.blockComment, Rule(#"(?<![:\w])//.*"#, .comment), P.dq, P.sq, Rule(#"@[\w-]+"#, .preprocessor),
                     Rule(#"#[0-9a-fA-F]{3,8}\b"#, .number), Rule(#"-?\d*\.?\d+(?:px|em|rem|%|vh|vw|vmin|vmax|s|ms|deg|pt|fr|ch|ex)?\b"#, .number),
                     Rule(#"[\w-]+(?=[ \t]*:[^:{;\n]*[;}\n])"#, .attribute), Rule(#"[.#][A-Za-z_-][\w-]*"#, .type),
                     Rule(#"\$[\w-]+|--[\w-]+"#, .variable)]
        css.highlightNumbers = false
        css.keywords = words("important inherit initial unset none auto")
        css.blockComment = ("/*", "*/")
        css.symbolPatterns = [#"^[ \t]*([^\s{}/][^{}\n;]*?)[ \t]*\{"#]
        list.append(css)

        var md = Language(name: "Markdown", extensions: ["md", "markdown", "mdown", "mkd", "mdx"])
        md.rules = [Rule(#"^[ \t]*```[\s\S]*?(?:^[ \t]*```|\z)"#, .string), Rule(#"`[^`\n]+`"#, .string),
                    Rule(#"^#{1,6}[ \t].*$"#, .heading), Rule(#"^.+\n(?:=+|-+)[ \t]*$"#, .heading),
                    Rule(#"^[ \t]*>.*$"#, .comment), Rule(#"<!--[\s\S]*?(?:-->|\z)"#, .comment),
                    Rule(#"!?\[[^\]\n]*\]\([^)\n]*\)|!?\[[^\]\n]*\]\[[^\]\n]*\]|<https?://[^>\s]+>"#, .link),
                    Rule(#"^[ \t]*\[[^\]\n]+\]:.*$"#, .link),
                    Rule(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .emphasis), Rule(#"(?<![*\w])\*[^*\s][^*\n]*\*(?!\*)|(?<!\w)_[^_\s][^_\n]*_(?!\w)"#, .emphasis),
                    Rule(#"^[ \t]*(?:[-*+]|\d+[.)])(?=[ \t])"#, .keyword), Rule(#"^[ \t]*(?:[-*_][ \t]*){3,}$"#, .keyword)]
        md.highlightNumbers = false
        md.blockComment = ("<!--", "-->")
        md.indentAfter = []
        md.symbolPatterns = [#"^#{1,6}[ \t]+(.+?)[ \t#]*$"#]
        list.append(md)

        var json = Language(name: "JSON", extensions: ["json", "jsonc", "geojson", "webmanifest"])
        json.rules = P.cStyle + [Rule(#""(?:\\.|[^"\\\n])*"(?=[ \t]*:)"#, .attribute), P.dq, Rule(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, .number)]
        json.keywords = words("true false null")
        json.highlightNumbers = false
        json.symbolPatterns = [#"^[ \t]{0,4}"([^"\n]+)"[ \t]*:"#]
        list.append(json)

        var yaml = Language(name: "YAML", extensions: ["yml", "yaml"])
        yaml.rules = [P.dq, P.sq, Rule(#"(?:^|(?<=\s))#.*"#, .comment), Rule(#"^---$|^\.\.\.$"#, .preprocessor),
                      Rule(#"^[ \t]*(?:-[ \t]+)?[^\s#:'"\-][^:#\n]*?(?=:(?:[ \t]|$))"#, .attribute),
                      Rule(#"[&*][\w-]+|!!?\w+"#, .variable)]
        yaml.keywords = words("true false null yes no on off True False Null")
        yaml.lineComment = "#"
        yaml.indentAfter = [":"]
        yaml.symbolPatterns = [#"^([A-Za-z_][\w.-]*)[ \t]*:"#]
        list.append(yaml)

        var ini = Language(name: "INI / Config", extensions: ["ini", "cfg", "conf", "toml", "properties", "env", "editorconfig", "gitconfig"])
        ini.filenames = [".gitconfig", ".editorconfig", ".env"]
        ini.rules = [Rule(#"^[ \t]*[;#].*$"#, .comment), Rule(#"^[ \t]*\[[^\]\n]*\]"#, .heading), P.dq, P.sq, Rule(#"^[ \t]*[\w.\-]+(?=[ \t]*[=:])"#, .attribute)]
        ini.keywords = words("true false yes no on off")
        ini.lineComment = "#"
        ini.symbolPatterns = [#"^[ \t]*\[([^\]\n]+)\]"#]
        list.append(ini)

        var make = Language(name: "Makefile", extensions: ["mk", "make"])
        make.filenames = ["Makefile", "makefile", "GNUmakefile"]
        make.rules = [P.hashComment, Rule(#"\$[({][^)}\n]*[)}]|\$[@<^?*%]"#, .variable), Rule(#"^[\w.%/ -]+(?=:(?!=))"#, .heading), P.dq, P.sq]
        make.keywords = words("ifeq ifneq ifdef ifndef else endif include define endef export override")
        make.lineComment = "#"
        make.highlightNumbers = false
        make.symbolPatterns = [#"^([\w.%/-]+)[ \t]*:(?!=)"#]
        list.append(make)

        return list
    }()

    private static let lock = NSLock()
    private static var _modules: [Language] = []

    /// Languages loaded from module files; these override built-ins of the same name.
    public static var modules: [Language] {
        get { lock.lock(); defer { lock.unlock() }; return _modules }
        set { lock.lock(); _modules = newValue; lock.unlock() }
    }

    public static var all: [Language] {
        let mods = modules
        return mods + builtIn.filter { b in !mods.contains { $0.name == b.name } }
    }

    public static var names: [String] { [plainText.name] + all.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }

    public static func named(_ name: String) -> Language {
        all.first { $0.name == name } ?? plainText
    }

    /// Picks a language from the file name, falling back to the shebang line.
    public static func detect(filename: String?, firstLine: String?) -> Language {
        if let filename {
            let base = (filename as NSString).lastPathComponent
            if let l = all.first(where: { $0.filenames.contains(base) }) { return l }
            let ext = (base as NSString).pathExtension.lowercased()
            if !ext.isEmpty, let l = all.first(where: { $0.extensions.contains(ext) }) { return l }
        }
        if let line = firstLine, line.hasPrefix("#!") {
            let parts = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "/" })
            // "#!/usr/bin/env python3" → look at the last meaningful word.
            for word in parts.reversed() {
                let w = word.trimmingCharacters(in: CharacterSet.decimalDigits.union(.punctuationCharacters))
                if let l = all.first(where: { $0.shebangs.contains(w) }) { return l }
            }
        }
        if let line = firstLine, line.hasPrefix("<?xml") { return named("XML") }
        if let line = firstLine?.lowercased(), line.hasPrefix("<!doctype html") || line.hasPrefix("<html") { return named("HTML") }
        return plainText
    }
}
