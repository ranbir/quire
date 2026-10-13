import XCTest
@testable import QuireCore

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let html = Markdown.html("# Title\n\nPara *em* **strong** `code` ~~gone~~.\n\n- a\n- b\n\n1. one\n2. two\n\n> quote\n\n---\n")
        XCTAssertTrue(html.contains("<h1 id=\"title\">Title</h1>"), html)
        XCTAssertTrue(html.contains("<p>Para <em>em</em> <strong>strong</strong> <code>code</code> <del>gone</del>.</p>"), html)
        XCTAssertTrue(html.contains("<ul>\n<li>a</li>\n<li>b</li>\n</ul>"), html)
        XCTAssertTrue(html.contains("<ol>\n<li>one</li>\n<li>two</li>\n</ol>"), html)
        XCTAssertTrue(html.contains("<blockquote>\n<p>quote</p>\n</blockquote>"), html)
        XCTAssertTrue(html.contains("<hr />"), html)
    }

    func testCodeIsEscapedAndNotFormatted() {
        let html = Markdown.html("```swift\nlet a = b < c && *d*\n```\n\nUse `<div>` **here**")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let a = b &lt; c &amp;&amp; *d*\n</code></pre>"), html)
        XCTAssertTrue(html.contains("<code>&lt;div&gt;</code> <strong>here</strong>"), html)
    }

    func testLinksImagesAndReferences() {
        let html = Markdown.html("See [site](http://x.com \"T\"), ![pic](a.png), [ref][r], <https://y.org> and https://z.net.\n\n[r]: http://r.com\n")
        XCTAssertTrue(html.contains("<a href=\"http://x.com\" title=\"T\">site</a>"), html)
        XCTAssertTrue(html.contains("<img src=\"a.png\" alt=\"pic\" />"), html)
        XCTAssertTrue(html.contains("<a href=\"http://r.com\">ref</a>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://y.org\">https://y.org</a>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://z.net\">https://z.net</a>."), html)
    }

    func testTablesAndTasks() {
        let html = Markdown.html("| a | b |\n|:--|--:|\n| 1 | 2 |\n\n- [x] done\n- [ ] todo\n")
        XCTAssertTrue(html.contains("<th align=\"left\">a</th>\n<th align=\"right\">b</th>"), html)
        XCTAssertTrue(html.contains("<td align=\"left\">1</td>"), html)
        XCTAssertTrue(html.contains("<li><input type=\"checkbox\" checked=\"\" disabled=\"\" /> done</li>"), html)
        XCTAssertTrue(html.contains("<li><input type=\"checkbox\" disabled=\"\" /> todo</li>"), html)
    }

    func testNestedListAndSetext() {
        let html = Markdown.html("Top\n===\n\n- a\n  - b\n- c\n")
        XCTAssertTrue(html.contains("<h1 id=\"top\">Top</h1>"), html)
        XCTAssertTrue(html.contains("<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>"), html)
    }

    func testRawHTMLPassesThroughAndTextIsEscaped() {
        let html = Markdown.html("<div class=\"x\">\nhi\n</div>\n\na < b & <span>c</span>")
        XCTAssertTrue(html.contains("<div class=\"x\">\nhi\n</div>"), html)
        XCTAssertTrue(html.contains("a &lt; b &amp; <span>c</span>"), html)
    }

    func testMermaidAndMathFences() {
        let html = Markdown.html("```mermaid\ngraph LR\n  A --> B\n```\n\n```math\na < b\n```\n")
        XCTAssertTrue(html.contains("<pre class=\"mermaid\">graph LR\n  A --&gt; B</pre>"), html)
        XCTAssertTrue(html.contains("<div class=\"math math-display\">a &lt; b</div>"), html)
    }

    func testD2AndGraphvizFences() {
        let html = Markdown.html("```d2\na -> b\n```\n\n```dot\ndigraph { a -> b }\n```\n\n```Graphviz\ngraph { a -- b }\n```\n\n```d2x\nnot a diagram\n```\n")
        XCTAssertTrue(html.contains("<pre class=\"d2\">a -&gt; b</pre>"), html)
        XCTAssertTrue(html.contains("<pre class=\"graphviz\">digraph { a -&gt; b }</pre>"), html)
        XCTAssertTrue(html.contains("<pre class=\"graphviz\">graph { a -- b }</pre>"), html)
        XCTAssertTrue(html.contains("<code class=\"language-d2x\">"), html)
        XCTAssertEqual(Markdown.diagramEngine(info: "dot {.wide}"), "graphviz")
        XCTAssertNil(Markdown.diagramEngine(info: "swift"))
    }

    func testDisplayMathBlocks() {
        let html = Markdown.html("Text\n$$\nx_1 * y_2\n$$\n\n$$ e^{i\\pi} $$\n\n$$ unclosed\n")
        XCTAssertTrue(html.contains("<p>Text</p>\n<div class=\"math math-display\">x_1 * y_2</div>"), html)
        XCTAssertTrue(html.contains("<div class=\"math math-display\"> e^{i\\pi} </div>"), html)
        XCTAssertTrue(html.contains("<p>$$ unclosed</p>"), html)
    }

    func testInlineMath() {
        let html = Markdown.html("Let $a_1 * b_2$ and $$\\sum_i x_i$$ hold; costs $5 or $6, \\$x\\$ and `$c$`.")
        XCTAssertTrue(html.contains("<span class=\"math math-inline\">a_1 * b_2</span>"), html)
        XCTAssertTrue(html.contains("<span class=\"math math-display\">\\sum_i x_i</span>"), html)
        XCTAssertTrue(html.contains("costs $5 or $6, $x$ and <code>$c$</code>."), html)
    }

    func testMathDoesNotCrossCodeSpansOrLines() {
        XCTAssertEqual(Markdown.html("a $x\ny$ b"), "<p>a $x\ny$ b</p>\n")
        XCTAssertEqual(Markdown.html("`$a` and $b$"), "<p><code>$a</code> and <span class=\"math math-inline\">b</span></p>\n")
        XCTAssertEqual(Markdown.html("$$\n$$"), "<div class=\"math math-display\"></div>\n")
        XCTAssertTrue(Markdown.html("```\n$$\nx\n$$\n```").contains("<pre><code>$$\nx\n$$\n</code></pre>"))
    }

    func testFrontMatter() {
        let doc = MarkdownDocument("---\ntitle: \"My Doc\"\ntags: [a, b]\n---\n# Hi\n")
        XCTAssertEqual(doc.frontMatter.map(\.key), ["title", "tags"])
        XCTAssertEqual(doc.frontMatter.first?.value, "My Doc")
        XCTAssertEqual(doc.frontMatterRange, NSRange(location: 0, length: 37))
        let html = doc.html()
        XCTAssertTrue(html.hasPrefix("<table class=\"front-matter\"><tr><th>title</th><td>My Doc</td></tr>"), html)
        XCTAssertTrue(html.contains("<h1 id=\"hi\">Hi</h1>"), html)
        // A thematic break followed by ordinary text is not front matter.
        XCTAssertTrue(MarkdownDocument("---\nJust a paragraph, then\n---\n").frontMatter.isEmpty)
    }

    func testAlerts() {
        let html = Markdown.html("> [!WARNING]\n> Hot *coffee*\n\n> [!TIP] inline is not an alert\n")
        XCTAssertTrue(html.contains("<div class=\"markdown-alert markdown-alert-warning\">\n<p class=\"markdown-alert-title\">Warning</p>\n<p>Hot <em>coffee</em></p>\n</div>"), html)
        XCTAssertTrue(html.contains("<blockquote>\n<p>[!TIP] inline is not an alert</p>\n</blockquote>"), html)
    }

    func testFootnotes() {
        let html = Markdown.html("Claim[^n].\n\n[^n]: Source.\n")
        XCTAssertTrue(html.contains("<sup class=\"footnote-ref\"><a href=\"#fn-n\" id=\"fnref-n\" data-footnote-ref>1</a></sup>"), html)
        XCTAssertTrue(html.contains("<section class=\"footnotes\" data-footnotes>"), html)
    }

    func testHeadingAnchorsAreUniqueAndGitHubStyle() {
        let doc = MarkdownDocument("# Set up & run_it\n## Set up & run_it\n### `code` *é*\n<h2>raw</h2>\n")
        XCTAssertEqual(doc.headings.map(\.id), ["set-up--run_it", "set-up--run_it-1", "code-é"])
        let html = doc.html()
        XCTAssertTrue(html.contains("<h2 id=\"set-up--run_it-1\">"), html)
        XCTAssertTrue(html.contains("<h2>raw</h2>"), html)
    }

    func testSourcePositionsOption() {
        XCTAssertEqual(Markdown.html("# A"), "<h1 id=\"a\">A</h1>\n")
        XCTAssertEqual(MarkdownDocument("# A\n\ntext").html(sourcePositions: true),
                       "<h1 id=\"a\" data-sourcepos=\"1:1-1:3\">A</h1>\n<p data-sourcepos=\"3:1-3:4\">text</p>\n")
    }

    func testSanitizeFiltersDangerousTags() {
        let html = Markdown.html("<script>x</script>\n\n<b>ok</b>", options: MarkdownOptions(sanitizeHTML: true))
        XCTAssertTrue(html.contains("&lt;script>"), html)
        XCTAssertTrue(html.contains("<b>ok</b>"), html)
    }

    func testTreeRangesAreUTF16() {
        let src = "# 🎉 Party\n\nSome **bold** and *é* text.\n\n- [x] done\n"
        let doc = MarkdownDocument(src)
        let ns = src as NSString
        func find(_ node: MarkdownNode, _ kind: MarkdownNode.Kind) -> MarkdownNode? {
            if node.kind == kind { return node }
            for c in node.children { if let f = find(c, kind) { return f } }
            return nil
        }
        let root = doc.root
        XCTAssertEqual(ns.substring(with: find(root, .heading(level: 1))!.range), "# 🎉 Party")
        XCTAssertEqual(ns.substring(with: find(root, .strong)!.range), "**bold**")
        XCTAssertEqual(ns.substring(with: find(root, .emphasis)!.range), "*é*")
        XCTAssertEqual(ns.substring(with: find(root, .item(checked: true))!.range), "- [x] done")
        XCTAssertEqual(doc.headings.first?.range, NSRange(location: 0, length: 10))
    }

    func testMathRangeAfterFrontMatterAndDisplayFence() {
        let src = "---\na: 1\n---\nLet $x^2$ be.\n\n$$\nE = mc^2\n$$\n"
        let doc = MarkdownDocument(src)
        let ns = src as NSString
        var found: [String] = []
        func visit(_ n: MarkdownNode) {
            if case .math = n.kind { found.append(ns.substring(with: n.range)) }
            if case .codeBlock(let info) = n.kind, info == "math" { found.append(ns.substring(with: n.range)) }
            n.children.forEach(visit)
        }
        visit(doc.root)
        XCTAssertEqual(found, ["$x^2$", "$$\nE = mc^2\n$$"])
    }

    func testPageLinksPreviewAssets() {
        let dir = URL(fileURLWithPath: "/tmp/preview assets")
        let page = Markdown.page(body: "<p>x</p>", title: "t", assets: dir)
        XCTAssertTrue(page.contains("<script defer src=\"file:///tmp/preview%20assets/quire-preview.js\"></script>"), page)
        XCTAssertTrue(page.contains("hljs/github-dark.min.css\" media=\"(prefers-color-scheme: dark)\""), page)
        XCTAssertFalse(Markdown.page(body: "", title: "t").contains("<script"))
    }
}

final class CompletionAndClippingTests: XCTestCase {
    func testCompletionRanking() {
        let text = "let counter = 1\ncounter += countdown\ncounter"
        let c = Completion.candidates(prefix: "cou", text: text, language: Languages.named("Swift"))
        XCTAssertEqual(c.first, "counter")
        XCTAssertTrue(c.contains("countdown"))
        XCTAssertTrue(Completion.candidates(prefix: "gua", text: "", language: Languages.named("Swift")).contains("guard"))
        XCTAssertFalse(Completion.candidates(prefix: "counter", text: text, language: Languages.named("Swift")).contains("counter"))
    }

    func testClippingExpansion() {
        let ctx = ClippingContext(selection: "body()", indent: "    ", fileName: "a.swift")
        let (t, sel) = Clippings.expand("if <#cond#> {\n    #SELECTION#\n}\n", context: ctx)
        XCTAssertEqual(t, "if <#cond#> {\n        body()\n    }\n")
        XCTAssertEqual(sel, NSRange(location: 3, length: 8))
        let (t2, sel2) = Clippings.expand("// #BASENAME#: #INSERTION#\n", context: ctx)
        XCTAssertEqual(t2, "// a: ")
        XCTAssertEqual(sel2, NSRange(location: 6, length: 0))
    }

    func testPlaceholderNavigation() {
        let s = "f(<#a#>, <#b#>)"
        XCTAssertEqual(Clippings.nextPlaceholder(in: s, after: 0), NSRange(location: 2, length: 5))
        XCTAssertEqual(Clippings.nextPlaceholder(in: s, after: 7), NSRange(location: 9, length: 5))
        XCTAssertEqual(Clippings.nextPlaceholder(in: s, after: 14), NSRange(location: 2, length: 5))
        XCTAssertEqual(Clippings.previousPlaceholder(in: s, before: 9), NSRange(location: 2, length: 5))
    }
}

final class FoldingTests: XCTestCase {
    func hidden(_ text: String, _ lang: String) -> [String] {
        let ns = text as NSString
        return FoldScanner.folds(in: text, language: Languages.named(lang)).map { ns.substring(with: $0.range) }
    }

    func testBraces() {
        let src = "func a() {\n  let s = \"{\"\n  if x {\n    y()\n  }\n}\n"
        XCTAssertEqual(hidden(src, "Swift"), ["\n  let s = \"{\"\n  if x {\n    y()\n  }\n", "\n    y()\n  "])
        let byLine = FoldScanner.foldsByLine(FoldScanner.folds(in: src, language: Languages.named("Swift")))
        XCTAssertEqual(Set(byLine.keys), [0, 2])
    }

    func testIndentation() {
        let src = "def a():\n    x = 1\n\n    y = 2\nz = 3\n"
        XCTAssertEqual(hidden(src, "Python"), ["\n    x = 1\n\n    y = 2"])
    }

    func testMarkdownHeadings() {
        let src = "# A\ntext\n## B\nmore\n\n# C\nend\n"
        XCTAssertEqual(hidden(src, "Markdown"), ["\ntext\n## B\nmore", "\nmore", "\nend"])
    }

    func testHTMLTags() {
        let src = "<div>\n  <p>x</p>\n  <br>\n</div>\n"
        XCTAssertEqual(hidden(src, "HTML"), ["\n  <p>x</p>\n  <br>\n"])
    }
}

final class GitTests: XCTestCase {
    func testChangeMarkers() {
        let m = LineDiff.changeMarkers(old: "a\nb\nc\nd\n", new: "a\nB\nc\nx\nd\n")
        XCTAssertEqual(m, [1: .modified, 3: .added])
        XCTAssertEqual(LineDiff.changeMarkers(old: "a\nb\nc\n", new: "a\nc\n"), [1: .deletedAbove])
        XCTAssertEqual(LineDiff.changeMarkers(old: "a\nb\n", new: "a\n"), [0: .deletedAbove])
    }

    func testRepositoryOperations() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("quire-git-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        try ProcessRunner.check(GitRepository.gitPath, ["init", "-q", "-b", "main"], cwd: dir)
        let repo = try XCTUnwrap(GitRepository.containing(file))
        try repo.git(["config", "user.email", "t@example.com"])
        try repo.git(["config", "user.name", "Tester"])
        XCTAssertEqual(try repo.status(), [GitStatusEntry(path: "f.txt", code: "??")])
        XCTAssertNil(repo.headContents(of: file))
        try repo.stage(file)
        XCTAssertEqual(try repo.status().first?.code, "A ")
        _ = try repo.commit(message: "first")
        XCTAssertEqual(repo.headContents(of: file), "one\ntwo\n")
        XCTAssertEqual(repo.currentBranch(), "main")
        try "one\n2\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try repo.status().first?.summary, "modified")
        let blame = try repo.blame(file)
        XCTAssertEqual(blame.map(\.text), ["one", "2"])
        XCTAssertEqual(blame.first?.author, "Tester")
        XCTAssertEqual(blame.first?.summary, "first")
        XCTAssertTrue(try repo.log(file).contains("first"))
        try repo.discardChanges(file)
        XCTAssertEqual(try String(contentsOf: file), "one\ntwo\n")
    }
}

final class ShellSessionTests: XCTestCase {
    func testStatePersistsBetweenCommands() throws {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let s = ShellSession(directory: dir)
        defer { s.terminate() }
        XCTAssertEqual(try s.run("echo hi").text, "hi\n")
        _ = try s.run("export QUIRE_X=42; cd /usr")
        let out = try s.run("echo $QUIRE_X; pwd")
        XCTAssertEqual(out.text, "42\n/usr\n")
        XCTAssertEqual(s.directory.path, "/usr")
        let fail = try s.run("echo oops >&2; false")
        XCTAssertEqual(fail.text, "oops\n")
        XCTAssertEqual(fail.status, 1)
        XCTAssertEqual(try s.run("printf 'no newline'").text, "no newline")
        XCTAssertEqual(try s.run("cat").text, "")   // stdin is /dev/null
    }

    func testTimeoutKillsAndRestarts() throws {
        let s = ShellSession(directory: URL(fileURLWithPath: "/tmp"))
        defer { s.terminate() }
        let r = try s.run("sleep 30", timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertEqual(try s.run("echo back").text, "back\n")
    }
}

final class RemoteTests: XCTestCase {
    func testParsing() {
        let a = RemoteLocation(string: "deploy@example.com:/var/www/index.html")
        XCTAssertEqual(a, RemoteLocation(user: "deploy", host: "example.com", path: "/var/www/index.html"))
        let b = RemoteLocation(string: "sftp://me@host:2222/~/notes.txt")
        XCTAssertEqual(b, RemoteLocation(user: "me", host: "host", port: 2222, path: "~/notes.txt"))
        XCTAssertEqual(RemoteLocation(string: "box:")?.path, "~")
        XCTAssertNil(RemoteLocation(string: "/local/path"))
        XCTAssertEqual(b?.display, "me@host:2222:~/notes.txt")
        XCTAssertEqual(RemoteLocation(user: nil, host: "h", path: "/a/b").parent.path, "/a")
    }

    func testQuotingAndListing() {
        XCTAssertEqual(SSHClient.quote("/a b/it's"), "'/a b/it'\\''s'")
        XCTAssertEqual(SSHClient.quote("~/x y"), "~/'x y'")
        let entries = SSHClient.parseListing("b.txt\na/\nrun*\nlink@\n.hidden\n")
        XCTAssertEqual(entries.map(\.name), ["a", ".hidden", "b.txt", "link", "run"])
        XCTAssertEqual(entries.first?.isDirectory, true)
        let client = SSHClient(controlDirectory: URL(fileURLWithPath: "/tmp/c"))
        let args = client.arguments(for: RemoteLocation(user: "u", host: "h", port: 22, path: "/x"), command: "ls")
        XCTAssertEqual(Array(args.suffix(5)), ["-p", "22", "--", "u@h", "ls"])
    }
}

final class LanguageModuleTests: XCTestCase {
    override func tearDown() { Languages.modules = [] }

    func testRoundTripBuiltInLanguage() throws {
        let swift = Languages.named("Swift")
        let decoded = try LanguageModule.decode(LanguageModule(language: swift).encoded()).language()
        XCTAssertEqual(decoded.keywords, swift.keywords)
        XCTAssertEqual(decoded.rules.map(\.pattern), swift.rules.map(\.pattern))
        XCTAssertEqual(decoded.lineComment, "//")
        XCTAssertEqual(decoded.indentAfter, swift.indentAfter)
    }

    func testLoadingModulesFromFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quire-mods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lua = #"{"name":"Lua","extensions":["lua"],"lineComment":"--","keywords":["local","function","end"],"rules":[{"pattern":"--.*","kind":"comment"}],"symbolPatterns":["function\\s+(\\w+)"]}"#
        try lua.write(to: dir.appendingPathComponent("lua.json"), atomically: true, encoding: .utf8)
        try #"{"name":"Bad","extensions":["bad"],"rules":[{"pattern":"(","kind":"comment"}]}"#.write(to: dir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        try #"{"extensions":[]}"#.write(to: dir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        let errors = Languages.loadModules(from: dir)
        XCTAssertEqual(errors.count, 2, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("invalid pattern") })
        XCTAssertTrue(errors.contains { $0.contains("missing key") })
        XCTAssertEqual(Languages.detect(filename: "x.lua", firstLine: nil).name, "Lua")
        let toks = Tokenizer(language: Languages.named("Lua")).tokenize("local x -- hi")
        XCTAssertEqual(toks.map(\.kind), [.keyword, .comment])
        XCTAssertEqual(SymbolScanner.symbols(in: "function go() end", language: Languages.named("Lua")).map(\.name), ["go"])
    }
}

final class OpenPathTests: XCTestCase {
    let base = URL(fileURLWithPath: "/work/proj")
    func resolve(_ s: String, existing: Set<String> = []) -> OpenPath.Location? {
        OpenPath.resolve(s, base: base, home: "/Users/me", exists: { existing.contains($0) })
    }

    func testPlainQuotedAndHome() {
        XCTAssertEqual(resolve("  /a/b.md\n"), .init(path: "/a/b.md"))
        XCTAssertEqual(resolve("\"/a/my notes.md\""), .init(path: "/a/my notes.md"))
        XCTAssertEqual(resolve("'~/x.txt'"), .init(path: "/Users/me/x.txt"))
        XCTAssertEqual(resolve("~"), .init(path: "/Users/me"))
        XCTAssertNil(resolve("   "))
    }

    func testTerminalEscapesAndFileURLs() {
        XCTAssertEqual(resolve(#"/a/my\ notes\ (1).md"#), .init(path: "/a/my notes (1).md"))
        XCTAssertEqual(resolve("file:///a/my%20notes.md"), .init(path: "/a/my notes.md"))
    }

    func testRelativeToBase() {
        XCTAssertEqual(resolve("docs/../README.md"), .init(path: "/work/proj/README.md"))
    }

    func testLineAndColumnSuffix() {
        let files: Set<String> = ["/a/b.swift"]
        XCTAssertEqual(resolve("/a/b.swift:42", existing: files), .init(path: "/a/b.swift", line: 42))
        XCTAssertEqual(resolve("/a/b.swift:42:7:", existing: files), .init(path: "/a/b.swift", line: 42, column: 7))
        // A file that really has a colon in its name wins over a line number.
        XCTAssertEqual(resolve("/a/c.md:3", existing: ["/a/c.md:3"]), .init(path: "/a/c.md:3"))
        // Missing file: keep the whole text so the error names what was typed.
        XCTAssertEqual(resolve("/nope.md:3"), .init(path: "/nope.md:3"))
    }
}
