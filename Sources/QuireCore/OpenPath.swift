import Foundation

/// Turns a pasted path into a file location for File ▸ Open Path…. Accepts what people
/// copy from Terminal, Finder, editors and compiler output: quoted paths, `~`,
/// backslash-escaped spaces, `file://` URLs and `path:line[:column]` suffixes.
public enum OpenPath {
    public struct Location: Equatable {
        public var path: String
        public var line: Int?
        public var column: Int?

        public init(path: String, line: Int? = nil, column: Int? = nil) {
            self.path = path
            self.line = line
            self.column = column
        }
    }

    private static let lineSuffix = try! NSRegularExpression(pattern: #"^(.+?):(\d+)(?::(\d+))?:?$"#)

    /// The location `input` names. Relative paths resolve against `base`. `exists` decides
    /// whether a `:line` suffix is part of the file name (a file really called `a.md:3`) or a line number.
    public static func resolve(_ input: String, base: URL, home: String = NSHomeDirectory(),
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Location? {
        var s = input.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        s = s.trimmingCharacters(in: .whitespaces)
        for q in ["\"", "'"] where s.count >= 2 && s.hasPrefix(q) && s.hasSuffix(q) {
            s = String(s.dropFirst().dropLast())
        }
        guard !s.isEmpty else { return nil }

        if s.lowercased().hasPrefix("file://") {
            guard let url = URL(string: s), url.isFileURL else { return nil }
            s = url.path
        } else if s.contains("\\") {
            // Terminal drag-and-drop escapes spaces and other characters: /a\ b.md
            s = s.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        }

        func absolute(_ p: String) -> String {
            if p == "~" { return home }
            if p.hasPrefix("~/") { return home + p.dropFirst(1) }
            if p.hasPrefix("/") { return (p as NSString).standardizingPath }
            return (base.appendingPathComponent(p).path as NSString).standardizingPath
        }

        let whole = absolute(s)
        if exists(whole) { return Location(path: whole) }
        let ns = s as NSString
        if let m = lineSuffix.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            let path = absolute(ns.substring(with: m.range(at: 1)))
            let line = Int(ns.substring(with: m.range(at: 2)))
            let column = m.range(at: 3).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 3)))
            if exists(path) { return Location(path: path, line: line, column: column) }
        }
        return Location(path: whole)
    }
}
