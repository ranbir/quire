import XCTest
@testable import QuireCore

final class ExportTests: XCTestCase {
    func testTitleFromFrontMatterHeadingOrFallback() {
        XCTAssertEqual(MarkdownExport.title(of: MarkdownDocument("---\ntitle: FM\n---\n# H\n"), fallback: "f"), "FM")
        XCTAssertEqual(MarkdownExport.title(of: MarkdownDocument("text\n\n## H *x*\n"), fallback: "f"), "H x")
        XCTAssertEqual(MarkdownExport.title(of: MarkdownDocument("text"), fallback: "f.md"), "f.md")
    }

    func testTableOfContentsNestsAndLinks() {
        let doc = MarkdownDocument("# A\n## B\n### C\n#### D\n## E\n# F\n")
        let toc = MarkdownExport.tableOfContents(doc.headings)
        XCTAssertEqual(toc, """
            <nav class="toc"><p class="toc-title">Contents</p>
            <ul>
            <li><a href="#a">A</a>
            <ul>
            <li><a href="#b">B</a>
            <ul>
            <li><a href="#c">C</a></li>
            </ul>
            </li>
            <li><a href="#e">E</a></li>
            </ul>
            </li>
            <li><a href="#f">F</a></li>
            </ul>
            </nav>

            """)
        XCTAssertEqual(MarkdownExport.tableOfContents([]), "")
    }

    func testBodyOmitsFrontMatterTableAndAddsTitlePage() {
        let doc = MarkdownDocument("---\ntitle: Report\nauthor: R & D\n---\n# Intro\n")
        var o = MarkdownExportOptions()
        o.titlePage = true
        let body = MarkdownExport.body(doc, title: "Report", options: o)
        XCTAssertFalse(body.contains("front-matter"), body)
        XCTAssertTrue(body.hasPrefix("<section class=\"title-page\"><h1 class=\"title\">Report</h1><p class=\"author\">R &amp; D</p></section>"), body)
        XCTAssertTrue(body.contains("<h1 id=\"intro\">Intro</h1>"), body)
    }

    func testLightOnlyRemovesDarkMediaBlocks() {
        let css = ":root { color-scheme: light dark; --a: 1 }\n@media (prefers-color-scheme: dark) { :root { --a: 2 } .x { y: z } }\n.b { c: d }"
        XCTAssertEqual(MarkdownExport.lightOnly(css), ":root { color-scheme: light; --a: 1 }\n\n.b { c: d }")
    }

    func testKatexCSSEmbedsOnlyUsedFonts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fonts = dir.appendingPathComponent("fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: fonts.appendingPathComponent("KaTeX_Main-Regular.woff2"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let css = #"@font-face{font-family:KaTeX_AMS;font-style:normal;font-weight:400;src:url(fonts/KaTeX_AMS-Regular.woff2) format("woff2")}@font-face{font-family:KaTeX_Main;font-style:normal;font-weight:400;src:url(fonts/KaTeX_Main-Regular.woff2) format("woff2"),url(fonts/KaTeX_Main-Regular.woff) format("woff")}.katex{font:normal 1.21em KaTeX_Main}"#
        let out = MarkdownExport.katexCSS(css, fonts: fonts, used: [("KaTeX_Main", "normal", "normal")])
        XCTAssertEqual(out, #"@font-face{font-family:KaTeX_Main;font-style:normal;font-weight:400;src:url(data:font/woff2;base64,AQID) format("woff2")}.katex{font:normal 1.21em KaTeX_Main}"#)
    }

    func testImagesEmbedCopyOrLink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("img"), withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(to: dir.appendingPathComponent("img/a b.png"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = #"<p><img src="img/a%20b.png" alt="x" /> <img src="https://e.com/r.png" /> <img src="missing.png" /></p>"#
        let embedded = MarkdownExport.processImages(html, base: dir, mode: .embed)
        XCTAssertTrue(embedded.contains(#"<img src="data:image/png;base64,iVA=" alt="x" />"#), embedded)
        XCTAssertTrue(embedded.contains(#"src="https://e.com/r.png""#) && embedded.contains(#"src="missing.png""#), embedded)
        XCTAssertEqual(MarkdownExport.processImages(html, base: dir, mode: .link), html)
        let files = dir.appendingPathComponent("out_files")
        let copied = MarkdownExport.processImages(html, base: dir, mode: .copy, filesDir: files)
        XCTAssertTrue(copied.contains(#"<img src="out_files/a%20b.png""#), copied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.appendingPathComponent("a b.png").path))
    }

    func testPageIsSelfContained() {
        let page = MarkdownExport.page(title: "T <1>", body: "<p>x</p>", stylesheets: ["a{}", "b{}"])
        XCTAssertTrue(page.contains("<title>T &lt;1&gt;</title>"))
        XCTAssertTrue(page.contains("<style>\na{}\nb{}\n</style>"), page)
        XCTAssertFalse(page.contains("<script"))
        XCTAssertFalse(page.contains("<link"))
    }
}

final class ExportThemeTests: XCTestCase {
    func testDarkOnlyKeepsDarkRulesUnconditionally() {
        let css = ":root { color-scheme: light dark; --a: 1 }\n@media (prefers-color-scheme: dark) { :root { --a: 2 } }\n.b { c: d }"
        XCTAssertEqual(MarkdownExport.darkOnly(css), ":root { color-scheme: dark; --a: 1 }\n :root { --a: 2 } \n.b { c: d }")
        XCTAssertEqual(MarkdownExport.onlyIn("dark", "x{}"), "@media (prefers-color-scheme: dark) {\nx{}\n}")
    }

    func testMergeDiagramsPairsLightAndDark() {
        let light = #"<p>a</p><figure class="diagram" data-source="g"><svg id="L1"></svg></figure><p>b</p><figure class="diagram"><svg id="L2"></svg></figure>"#
        let dark = #"<p>a</p><figure class="diagram" data-source="g"><svg id="D1"></svg></figure><p>b</p><figure class="diagram"><svg id="D2"></svg></figure>"#
        XCTAssertEqual(MarkdownExport.mergeDiagrams(light: light, dark: dark),
                       #"<p>a</p><figure class="only-light diagram" data-source="g"><svg id="L1"></svg></figure><figure class="only-dark diagram" data-source="g"><svg id="D1"></svg></figure><p>b</p><figure class="only-light diagram"><svg id="L2"></svg></figure><figure class="only-dark diagram"><svg id="D2"></svg></figure>"#)
    }

    func testSmartPunctuationOption() {
        XCTAssertEqual(Markdown.html("\"Hi\" -- it's...", options: MarkdownOptions(smartPunctuation: true)), "<p>“Hi” – it’s…</p>\n")
        XCTAssertEqual(Markdown.html("\"Hi\""), "<p>&quot;Hi&quot;</p>\n")
    }
}
