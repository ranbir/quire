import XCTest
@testable import QuireCore

final class SpanTests: XCTestCase {
    func markers(_ src: String) -> [String] {
        let ns = src as NSString
        return MarkdownDocument(src).spans.compactMap { s in
            if case .marker(let m) = s.kind { return "\(m):\(ns.substring(with: s.range))" }
            return nil
        }
    }

    func kinds(_ src: String) -> [String] {
        let ns = src as NSString
        return MarkdownDocument(src).spans.compactMap { s in
            if case .marker = s.kind { return nil }
            return "\(s.kind)=\(ns.substring(with: s.range))"
        }
    }

    func testInlineMarkers() {
        XCTAssertEqual(markers("Some **bold**, *em*, ~~gone~~, `code` and \\*not\\*."),
                       ["emphasis:**", "emphasis:**", "emphasis:*", "emphasis:*", "emphasis:~~", "emphasis:~~",
                        "code:`", "code:`", "escape:\\", "escape:\\"])
        XCTAssertEqual(kinds("A **b** `c`"), ["strong=**b**", "code=`c`"])
    }

    func testLinksAndImages() {
        XCTAssertEqual(markers("[text](http://x.com \"T\") ![alt](a.png) <https://y.org> https://z.net [ref][r]\n\n[r]: /u\n"),
                       ["link:[", "url:](http://x.com \"T\")", "link:![", "url:](a.png)", "link:<", "link:>", "link:[", "url:][r]"])
        XCTAssertTrue(kinds("see https://z.net now").contains("autolink(url: \"https://z.net\")=https://z.net"))
    }

    func testHeadings() {
        XCTAssertEqual(markers("# Title #\n\nSub\n---\n"), ["heading:# ", "heading: #", "heading:---"])
        XCTAssertEqual(kinds("## Two"), ["heading(level: 2)=## Two"])
    }

    func testBlocks() {
        let src = "> quote\n> more\n\n- a\n- [x] done\n  1. one\n\n```swift\nlet x = 1\n```\n\n***\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        XCTAssertEqual(markers(src), ["quote:> ", "quote:> ", "bullet:- ", "bullet:- ", "task:[x] ", "bullet:1. ",
                                      "fence:```swift", "fence:```", "rule:***",
                                      "table:|", "table:|", "table:|", "table:|---|---|", "table:|", "table:|", "table:|"])
    }

    func testMathAndFrontMatter() {
        let src = "---\ntitle: x\n---\nLet $a$ be.\n\n$$\nb\n$$\n"
        XCTAssertEqual(markers(src), ["math:$", "math:$", "fence:$$", "fence:$$"])
        XCTAssertEqual(kinds(src).first, "frontMatter=---\ntitle: x\n---\n")
    }

    func testAlerts() {
        let src = "> [!Warning]\n> Careful.\n\n> [!TIP] not alone\n"
        XCTAssertEqual(markers(src), ["quote:> ", "quote:> ", "alert:[!", "alert:]", "quote:> "])
        XCTAssertTrue(kinds(src).contains("alert(\"warning\")=> [!Warning]\n> Careful."), "\(kinds(src))")
        XCTAssertTrue(kinds(src).contains("alertTitle(\"warning\")=Warning"))
    }

    func testBlocksForLiveReveal() {
        let src = "Para with **bold**.\n\n- item *em*\n"
        let ns = src as NSString
        let spans = MarkdownDocument(src).spans
        let bold = spans.first { $0.kind == .marker(.emphasis) }!
        XCTAssertEqual(ns.substring(with: bold.block), "Para with **bold**.")
        let bullet = spans.first { $0.kind == .marker(.bullet) }!
        XCTAssertEqual(ns.substring(with: bullet.block), "- item *em*")
    }

    /// Every marker in every spec example covers only markup characters.
    func testMarkersAcrossSpecCorpus() throws {
        let patterns: [MarkdownSpan.Marker: String] = [
            .heading: #"^(#{1,6}[ \t]*|[ \t]+#+[ \t]*| {0,3}(=+|-+)[ \t]*)$"#,
            .emphasis: #"^(\*+|_+|~+)$"#, .code: "^`+$", .link: #"^(\[|!\[|<|>)$"#, .url: #"^\]"#,
            .quote: #"^>[ \t]?$"#, .bullet: #"^([-*+]|\d{1,9}[.)])[ \t]*$"#, .task: #"^\[[ xX]\][ \t]?$"#,
            .fence: #"^(`{3,}|~{3,}|\$\$)"#, .rule: #"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#, .math: #"^\$\$?$"#,
            .escape: #"^\\$"#, .lineBreak: #"^\\$"#, .table: #"^(\||[ \t|:-]+)$"#, .alert: #"^(\[!|\])$"#,
        ]
        var bad: [String] = []
        var count = 0
        for file in ["commonmark-0.31.2.txt", "gfm-spec.txt"] {
            for ex in try SpecTests.examples(file) {
                let ns = ex.markdown as NSString
                for s in MarkdownDocument(ex.markdown).spans {
                    guard s.range.location >= 0, NSMaxRange(s.range) <= ns.length else {
                        bad.append("\(file) #\(ex.number) out of bounds \(s.kind) \(s.range) in \(ex.markdown.debugDescription)")
                        continue
                    }
                    guard case .marker(let m) = s.kind else { continue }
                    count += 1
                    let text = ns.substring(with: s.range)
                    if text.range(of: patterns[m]!, options: .regularExpression) == nil {
                        bad.append("\(file) #\(ex.number) \(m): \(text.debugDescription) in \(ex.markdown.debugDescription)")
                    }
                }
            }
        }
        print("checked \(count) markers")
        XCTAssertGreaterThan(count, 2000)
        XCTAssertEqual(bad, [], bad.prefix(15).joined(separator: "\n"))
    }

    func testHeadingFoldsAndSymbolsUseTheParser() {
        let md = Languages.named("Markdown")
        let text = "# One\ntext\n```\n# not a heading\n```\nSetext\n---\nmore\n## Two\nend\n"
        let symbols = SymbolScanner.symbols(in: text, language: md)
        XCTAssertEqual(symbols.map(\.name), ["One", "  Setext", "  Two"])
        XCTAssertEqual(symbols.map(\.line), [1, 6, 9])
        let folds = FoldScanner.folds(in: text, language: md)
        XCTAssertEqual(folds.map(\.line), [0, 5, 8])
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: folds[1].range), "\nmore")
    }

    func testWordCount() {
        XCTAssertEqual(MarkdownDocument("---\ntitle: Not counted here\n---\n# Two words\n\nSome **bold** text and [a link](https://x.y/z).\n").wordCount, 8)
    }
}
