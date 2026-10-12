import XCTest
@testable import QuireCore

final class MarkdownEditingTests: XCTestCase {
    func apply(_ text: String, _ e: MarkdownEditing.Edit?) -> String {
        guard let e else { return text }
        return (text as NSString).replacingCharacters(in: e.range, with: e.replacement)
    }

    func caret(_ text: String) -> (String, Int) {
        let r = (text as NSString).range(of: "|")
        return ((text as NSString).replacingCharacters(in: r, with: ""), r.location)
    }

    func newline(_ marked: String) -> String? {
        let (t, c) = caret(marked)
        guard let e = MarkdownEditing.newline(in: t, cursor: c) else { return nil }
        let out = apply(t, e) as NSString
        return out.replacingCharacters(in: NSRange(location: e.selection.location, length: 0), with: "|")
    }

    func testListContinuation() {
        XCTAssertEqual(newline("- one|"), "- one\n- |")
        XCTAssertEqual(newline("  * deep|"), "  * deep\n  * |")
        XCTAssertEqual(newline("9. nine|"), "9. nine\n10. |")
        XCTAssertEqual(newline("1) a|"), "1) a\n2) |")
        XCTAssertEqual(newline("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(newline("- sp|lit"), "- sp\n- |lit")
        XCTAssertNil(newline("|- before marker"))
        XCTAssertNil(newline("plain|"))
    }

    func testEmptyItemEndsOrOutdents() {
        XCTAssertEqual(newline("- a\n- |"), "- a\n|")
        XCTAssertEqual(newline("- a\n    - |"), "- a\n- |")
        XCTAssertEqual(newline("- [ ] |"), "|")
    }

    func testQuoteContinuation() {
        XCTAssertEqual(newline("> quote|"), "> quote\n> |")
        XCTAssertEqual(newline("> > deep|"), "> > deep\n> > |")
        XCTAssertEqual(newline("> |"), "|")
    }

    func testRenumber() {
        let text = "1. a\n1. b\n   - nested\n7. c\n\nafter\n1. other"
        let e = MarkdownEditing.renumber(text, around: 0)
        XCTAssertEqual(apply(text, e), "1. a\n2. b\n   - nested\n3. c\n\nafter\n1. other")
        XCTAssertNil(MarkdownEditing.renumber("1. a\n2. b\n", around: 0))
        XCTAssertNil(MarkdownEditing.renumber("- a\n- b\n", around: 0))
        let start = "3. a\n9. b"
        XCTAssertEqual(apply(start, MarkdownEditing.renumber(start, around: 7)), "3. a\n4. b")
    }

    func wrap(_ marked: String, _ marker: String) -> String {
        // [ ] marks the selection, | an empty one
        let ns = marked as NSString
        var sel: NSRange
        var text: String
        if ns.range(of: "[").location != NSNotFound {
            let a = ns.range(of: "[").location, b = ns.range(of: "]").location
            text = ns.replacingCharacters(in: NSRange(location: b, length: 1), with: "")
            text = (text as NSString).replacingCharacters(in: NSRange(location: a, length: 1), with: "")
            sel = NSRange(location: a, length: b - a - 1)
        } else {
            let c = ns.range(of: "|").location
            text = ns.replacingCharacters(in: NSRange(location: c, length: 1), with: "")
            sel = NSRange(location: c, length: 0)
        }
        let e = MarkdownEditing.toggleWrap(text, selection: sel, marker: marker)
        let out = apply(text, e) as NSString
        if e.selection.length == 0 { return out.replacingCharacters(in: NSRange(location: e.selection.location, length: 0), with: "|") }
        let withEnd = out.replacingCharacters(in: NSRange(location: NSMaxRange(e.selection), length: 0), with: "]") as NSString
        return withEnd.replacingCharacters(in: NSRange(location: e.selection.location, length: 0), with: "[")
    }

    func testToggleWrap() {
        XCTAssertEqual(wrap("make [this] bold", "**"), "make **[this]** bold")
        XCTAssertEqual(wrap("make **[this]** bold", "**"), "make [this] bold")
        XCTAssertEqual(wrap("make [**this**] bold", "**"), "make [this] bold")
        XCTAssertEqual(wrap("wo|rd here", "*"), "*[word]* here")
        XCTAssertEqual(wrap("x | y", "`"), "x `|` y")
        XCTAssertEqual(wrap("**[bold]**", "*"), "***[bold]***")
        XCTAssertEqual(wrap("***[both]***", "*"), "**[both]**")
        XCTAssertEqual(wrap("[gone]", "~~"), "~~[gone]~~")
    }

    func testLinkHeadingAndHelpers() {
        let e = MarkdownEditing.link("see docs now", selection: NSRange(location: 4, length: 4), url: nil)
        XCTAssertEqual(apply("see docs now", e), "see [docs](url) now")
        XCTAssertEqual(e.selection, NSRange(location: 11, length: 3))
        XCTAssertEqual(apply("x", MarkdownEditing.link("x", selection: NSRange(location: 0, length: 1), url: "https://a.b")), "[x](https://a.b)")

        XCTAssertEqual(apply("Title", MarkdownEditing.heading("Title", cursor: 2, level: 2)), "## Title")
        XCTAssertEqual(apply("## Title", MarkdownEditing.heading("## Title", cursor: 5, level: 1)), "# Title")
        XCTAssertEqual(apply("## Title", MarkdownEditing.heading("## Title", cursor: 5, level: 2)), "Title")
        XCTAssertEqual(MarkdownEditing.heading("## Title", cursor: 5, level: 1).selection.location, 4)

        XCTAssertTrue(MarkdownEditing.isLinkable("https://example.com/a?b=1"))
        XCTAssertTrue(MarkdownEditing.isLinkable(" mailto:a@b.c\n"))
        XCTAssertFalse(MarkdownEditing.isLinkable("not a url"))
        XCTAssertFalse(MarkdownEditing.isLinkable("file:///etc/hosts"))

        XCTAssertEqual(MarkdownEditing.relativePath(of: URL(fileURLWithPath: "/a/b/assets/p q.png"), from: URL(fileURLWithPath: "/a/b")), "assets/p%20q.png")
        XCTAssertEqual(MarkdownEditing.relativePath(of: URL(fileURLWithPath: "/a/img.png"), from: URL(fileURLWithPath: "/a/b/c")), "../../img.png")
    }
}

final class MarkdownTableTests: XCTestCase {
    func run(_ text: String, _ e: MarkdownEditing.Edit?) -> String {
        guard let e else { return "nil" }
        let out = (text as NSString).replacingCharacters(in: e.range, with: e.replacement) as NSString
        return out.replacingCharacters(in: NSRange(location: e.selection.location, length: 0), with: "|>")
    }

    func testTabFormatsAndMovesToNextCell() {
        let t = "| a | longer |\n|---|:-:|\n| x | y |"
        let cursor = (t as NSString).range(of: "x").location
        XCTAssertEqual(run(t, MarkdownEditing.tableTab(t, cursor: cursor)),
                       "| a   | longer |\n| --- | :----: |\n| x   |   |>y    |")
    }

    func testTabAfterLastCellAddsRow() {
        let t = "| a | b |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(run(t, MarkdownEditing.tableTab(t, cursor: (t as NSString).length - 2)),
                       "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| |>    |     |")
    }

    func testShiftTabAndAlignment() {
        let t = "Name | Qty\n:--|--:\nApple | 3\n"
        let cursor = (t as NSString).range(of: "3").location
        XCTAssertEqual(run(t, MarkdownEditing.tableTab(t, cursor: cursor, backward: true)),
                       "| Name  | Qty |\n| :---- | --: |\n| |>Apple |   3 |\n")
    }

    func testReturnAddsRowAndNonTablesAreIgnored() {
        let t = "| a | b |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(run(t, MarkdownEditing.tableNewline(t, cursor: (t as NSString).length)),
                       "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| |>    |     |")
        XCTAssertEqual(run("a | b\nnot a table", MarkdownEditing.tableTab("a | b\nnot a table", cursor: 1)), "nil")
    }

    func testPipesInCodeAndEscapesStayInCells() {
        XCTAssertEqual(MarkdownEditing.cells("| `a|b` | c\\|d |"), ["`a|b`", "c\\|d"])
    }
}
