import XCTest
@testable import QuireCore

final class CodecTests: XCTestCase {
    func testDetectsAndRestoresCRLF() throws {
        let d = TextCodec.decode(Data("a\r\nb\r\n".utf8))
        XCTAssertEqual(d.text, "a\nb\n")
        XCTAssertEqual(d.lineEnding, .crlf)
        let out = try TextCodec.encode(d.text, encoding: d.encoding, lineEnding: d.lineEnding, bom: d.hasBOM)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "a\r\nb\r\n")
    }

    func testUTF8BOMRoundTrip() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("hé".utf8))
        let d = TextCodec.decode(data)
        XCTAssertTrue(d.hasBOM)
        XCTAssertEqual(d.text, "hé")
        XCTAssertEqual(try TextCodec.encode(d.text, encoding: .utf8, lineEnding: .lf, bom: true), data)
    }

    func testFallsBackToLegacyEncoding() {
        let d = TextCodec.decode(Data([0x63, 0x61, 0x66, 0xE9]))   // "café" in Latin-1/CP1252
        XCTAssertEqual(d.text, "café")
        XCTAssertNotEqual(d.encoding, .utf8)
    }

    func testEncodingFailureThrows() {
        XCTAssertThrowsError(try TextCodec.encode("日本", encoding: .ascii, lineEnding: .lf, bom: false))
    }

    func testLineIndex() {
        let idx = LineIndex("ab\ncd\n\nef")
        XCTAssertEqual(idx.lineCount, 4)
        XCTAssertEqual(idx.line(for: 0), 0)
        XCTAssertEqual(idx.line(for: 3), 1)
        XCTAssertEqual(idx.line(for: 6), 2)
        XCTAssertEqual(idx.range(ofLine: 3), NSRange(location: 7, length: 2))
        XCTAssertEqual(idx.range(ofLine: 2), NSRange(location: 6, length: 0))
    }
}

final class TransformTests: XCTestCase {
    func testSortAndDedupe() {
        XCTAssertEqual(TextTransforms.sortLines("b\na\nC\n"), "a\nb\nC\n")
        XCTAssertEqual(TextTransforms.sortLines("10\n9\n100", .init(numeric: true)), "9\n10\n100")
        XCTAssertEqual(TextTransforms.removeDuplicateLines("x\ny\nx\n"), "x\ny\n")
    }

    func testTitleCase() {
        XCTAssertEqual(TextTransforms.titleCase("the lord of the rings"), "The Lord of the Rings")
        XCTAssertEqual(TextTransforms.titleCase("using an iPhone in macOS"), "Using an iPhone in macOS")
    }

    func testTabs() {
        XCTAssertEqual(TextTransforms.detab("\tx\ty", tabWidth: 4), "    x   y")
        XCTAssertEqual(TextTransforms.entab("        x", tabWidth: 4), "\t\tx")
        XCTAssertEqual(TextTransforms.shiftLeft("    a\n\tb\n  c", tabWidth: 4), "a\nb\nc")
    }

    func testCommentToggle() {
        let on = TextTransforms.toggleLineComment("  a\n\n  b\n", prefix: "//")
        XCTAssertEqual(on, "  // a\n\n  // b\n")
        XCTAssertEqual(TextTransforms.toggleLineComment(on, prefix: "//"), "  a\n\n  b\n")
        XCTAssertEqual(TextTransforms.toggleBlockComment("x", open: "<!--", close: "-->"), "<!-- x -->")
        XCTAssertEqual(TextTransforms.toggleBlockComment("<!-- x -->", open: "<!--", close: "-->"), "x")
    }

    func testWrapping() {
        XCTAssertEqual(TextTransforms.hardWrap("one two three four", width: 9), "one two\nthree\nfour")
        XCTAssertEqual(TextTransforms.removeLineBreaks("a\nb\n\nc\nd\n"), "a b\n\nc d\n")
    }

    func testNumbersAndGremlins() {
        let numbered = TextTransforms.addLineNumbers("a\nb", start: 9)
        XCTAssertEqual(numbered, " 9 a\n10 b")
        XCTAssertEqual(TextTransforms.removeLineNumbers(numbered), "a\nb")
        XCTAssertEqual(TextTransforms.zapGremlins("a\u{200B}b\u{00A0}c\u{0007}"), "ab c")
        XCTAssertEqual(TextTransforms.stripTrailingWhitespace("a  \nb\t\n"), "a\nb\n")
    }

    func testQuotesAndJSON() throws {
        XCTAssertEqual(TextTransforms.educateQuotes("\"hi\" it's"), "“hi” it’s")
        XCTAssertEqual(TextTransforms.straightenQuotes("“hi” it’s"), "\"hi\" it's")
        XCTAssertEqual(try TextTransforms.formatJSON("{\"a\":[1]}"), "{\n  \"a\" : [\n    1\n  ]\n}")
        XCTAssertThrowsError(try TextTransforms.formatJSON("{nope"))
    }

    func testStatistics() {
        XCTAssertEqual(TextTransforms.statistics("hello world\nbye\n"), .init(characters: 16, words: 3, lines: 2))
    }
}

final class SearchTests: XCTestCase {
    func testReplacementTemplate() {
        XCTAssertEqual(SearchEngine.replacementTemplate(#"\2-\1 & $x\n"#, grep: true), "$2-$1 $0 \\$x\n")
        XCTAssertEqual(SearchEngine.replacementTemplate("$1", grep: false), "\\$1")
    }

    func testGrepReplace() throws {
        let r = try SearchEngine.regex(for: .init(pattern: #"(\w+)@(\w+)"#, grep: true))
        let t = SearchEngine.replacementTemplate(#"\2 at \1"#, grep: true)
        let s = "me@home"
        XCTAssertEqual(r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: 7), withTemplate: t), "home at me")
    }

    func testFindWrapsAndGoesBackwards() throws {
        let text = "cat dog cat"
        let r = try SearchEngine.regex(for: .init(pattern: "cat"))
        XCTAssertEqual(SearchEngine.find(in: text, regex: r, from: NSRange(location: 0, length: 3), backwards: false, wrap: true), NSRange(location: 8, length: 3))
        XCTAssertEqual(SearchEngine.find(in: text, regex: r, from: NSRange(location: 8, length: 3), backwards: false, wrap: true), NSRange(location: 0, length: 3))
        XCTAssertNil(SearchEngine.find(in: text, regex: r, from: NSRange(location: 8, length: 3), backwards: false, wrap: false))
        XCTAssertEqual(SearchEngine.find(in: text, regex: r, from: NSRange(location: 8, length: 3), backwards: true, wrap: true), NSRange(location: 0, length: 3))
    }

    func testWholeWordAndCase() throws {
        let r = try SearchEngine.regex(for: .init(pattern: "Cat", caseSensitive: true, wholeWord: true))
        XCTAssertEqual(SearchEngine.findAll(in: "Cat cat Category\nCat", regex: r).map(\.line), [1, 2])
    }

    func testFolderSearch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "let needle = 1\n".write(to: dir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "needle\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "needle\n".write(to: dir.appendingPathComponent("node_modules/c.swift"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2] + Array("needle".utf8)).write(to: dir.appendingPathComponent("d.swift"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = try SearchEngine.searchFolder(dir, options: .init(pattern: "needle"), fileFilter: "*.swift")
        XCTAssertEqual(hits.map { $0.url?.lastPathComponent }, ["a.swift"])
        XCTAssertEqual(hits.first?.column, 4)
    }
}

final class DiffTests: XCTestCase {
    func testUnifiedDiff() {
        let d = LineDiff.unified(old: "a\nb\nc\n", new: "a\nB\nc\nd\n", oldName: "x", newName: "y")
        XCTAssertEqual(d, "--- x\n+++ y\n@@ -1,3 +1,4 @@\n a\n-b\n+B\n c\n+d\n")
        XCTAssertEqual(LineDiff.unified(old: "same", new: "same", oldName: "x", newName: "y"), "")
    }
}

final class TokenizerTests: XCTestCase {
    func kinds(_ text: String, _ lang: String) -> [(String, TokenKind)] {
        let ns = text as NSString
        return Tokenizer(language: Languages.named(lang)).tokenize(text).map { (ns.substring(with: $0.range), $0.kind) }
    }

    func testSwift() {
        let k = kinds(#"let s = "a // b" // note"#, "Swift")
        XCTAssertEqual(k.map(\.0), ["let", #""a // b""#, "// note"])
        XCTAssertEqual(k.map(\.1), [.keyword, .string, .comment])
    }

    func testTypesAndNumbers() {
        let k = kinds("var x: Int = 0x1F", "Swift")
        XCTAssertEqual(k.map(\.1), [.keyword, .type, .number])
    }

    func testHTMLInnerRules() {
        let k = kinds(#"<a href="x">don't</a>"#, "HTML")
        XCTAssertTrue(k.contains { $0 == ("href", .attribute) })
        XCTAssertTrue(k.contains { $0 == (#""x""#, .string) })
        XCTAssertFalse(k.contains { $0.0.contains("don") })
    }

    func testSQLCaseInsensitive() {
        XCTAssertEqual(kinds("SELECT x FROM t", "SQL").map(\.1), [.keyword, .keyword])
    }

    func testDetection() {
        XCTAssertEqual(Languages.detect(filename: "x.py", firstLine: nil).name, "Python")
        XCTAssertEqual(Languages.detect(filename: "Makefile", firstLine: nil).name, "Makefile")
        XCTAssertEqual(Languages.detect(filename: "run", firstLine: "#!/usr/bin/env python3").name, "Python")
        XCTAssertEqual(Languages.detect(filename: "run", firstLine: "#!/bin/zsh").name, "Shell Script")
        XCTAssertEqual(Languages.detect(filename: nil, firstLine: nil).name, "Plain Text")
    }

    func testSymbols() {
        let src = "class Foo {\n  func bar() {}\n  if x { }\n}\nstruct Baz {}\n"
        XCTAssertEqual(SymbolScanner.symbols(in: src, language: Languages.named("Swift")).map(\.name), ["Foo", "bar", "Baz"])
        let py = "def a():\n    pass\nclass B:\n    async def c(self): ...\n"
        XCTAssertEqual(SymbolScanner.symbols(in: py, language: Languages.named("Python")).map(\.name), ["a", "B", "c"])
    }

    func testAllLanguagePatternsCompile() {
        for lang in Languages.all {
            for rule in lang.rules {
                XCTAssertNoThrow(try NSRegularExpression(pattern: rule.pattern), "\(lang.name): \(rule.pattern)")
            }
            for p in lang.symbolPatterns {
                XCTAssertNoThrow(try NSRegularExpression(pattern: p), "\(lang.name) symbol: \(p)")
            }
        }
    }
}
