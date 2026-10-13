import AppKit
import PDFKit
import QuireCore

/// Exercises the AppKit editor layer against a real document and text view.
/// Run with QUIRE_SELFTEST=1; exits 0 on success, 1 on failure.
enum SelfTest {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "PASS" : "FAIL", name, ok ? "" : detail())
            if !ok { failures += 1 }
        }

        // Undo groups (and the document's change count) close at the end of an event-loop pass.
        // Explicit undo groups stand in for AppKit's per-event grouping.
        func step(_ tv: NSTextView, _ f: () -> Void) {
            let um = tv.undoManager!
            um.beginUndoGrouping(); f(); um.endUndoGrouping()
        }

        func makeEditor(_ text: String, name: String = "t.swift") throws -> (Document, EditorTextView) {
            let doc = Document()
            doc.fileURL = URL(fileURLWithPath: "/tmp/\(name)")
            try doc.read(from: Data(text.utf8), ofType: "public.plain-text")
            doc.makeWindowControllers()
            doc.undoManager?.groupsByEvent = false
            return (doc, doc.editor.textView)
        }

        do {
            // CRLF round trip
            let (doc, tv) = try makeEditor("a\r\nb\r\n", name: "x.txt")
            check("CRLF normalized in editor", tv.string == "a\nb\n", tv.string.debugDescription)
            let saved = String(decoding: try doc.data(ofType: "public.plain-text"), as: UTF8.self)
            check("CRLF restored on save", saved == "a\r\nb\r\n", saved.debugDescription)

            // Line moves
            let (_, t2) = try makeEditor("one\ntwo\nthree")
            t2.setSelectedRange(NSRange(location: 1, length: 0))
            step(t2) { t2.moveLineDown(nil) }
            check("move line down", t2.string == "two\none\nthree", t2.string.debugDescription)
            check("caret follows moved line", t2.selectedRange().location == 5, "\(t2.selectedRange())")
            t2.setSelectedRange(NSRange(location: 9, length: 0))   // in "three"
            step(t2) { t2.moveLineUp(nil) }
            check("move last line up", t2.string == "two\nthree\none", t2.string.debugDescription)
            t2.undoManager?.undo()
            check("undo move", t2.string == "two\none\nthree", t2.string.debugDescription)

            t2.setSelectedRange(NSRange(location: 0, length: 0))
            step(t2) { t2.duplicateLine(nil) }
            check("duplicate line", t2.string == "two\ntwo\none\nthree", t2.string.debugDescription)
            t2.setSelectedRange(NSRange(location: (t2.string as NSString).length, length: 0))
            step(t2) { t2.deleteLine(nil) }
            check("delete last line", t2.string == "two\ntwo\none", t2.string.debugDescription)

            // Comment toggle uses the language's prefix
            let (_, t3) = try makeEditor("let a = 1\nlet b = 2\n")
            t3.setSelectedRange(NSRange(location: 0, length: 19))
            step(t3) { t3.toggleComment(nil) }
            check("comment lines", t3.string == "// let a = 1\n// let b = 2\n", t3.string.debugDescription)
            step(t3) { t3.toggleComment(nil) }
            check("uncomment lines", t3.string == "let a = 1\nlet b = 2\n", t3.string.debugDescription)

            // Auto-indent and close-brace outdent
            let (_, t4) = try makeEditor("    if x {")
            t4.setSelectedRange(NSRange(location: 10, length: 0))
            step(t4) { t4.insertNewline(nil) }
            check("auto-indent after {", t4.string == "    if x {\n        ", t4.string.debugDescription)
            step(t4) { t4.insertNewline(nil) }
            step(t4) { t4.insertText("}", replacementRange: t4.selectedRange()) }
            check("outdent on }", t4.string.hasSuffix("\n    }"), t4.string.debugDescription)

            // Expand tabs
            let (_, t5) = try makeEditor("ab")
            t5.setSelectedRange(NSRange(location: 2, length: 0))
            step(t5) { t5.insertTab(nil) }
            check("tab expands to next stop", t5.string == "ab  ", t5.string.debugDescription)

            // Balance
            let (_, t6) = try makeEditor("f(a, [b, c])")
            t6.setSelectedRange(NSRange(location: 7, length: 0))
            t6.balance(nil)
            check("balance inner", t6.selectedRange() == NSRange(location: 6, length: 4), "\(t6.selectedRange())")
            t6.balance(nil)
            check("balance widens to brackets", t6.selectedRange() == NSRange(location: 5, length: 6), "\(t6.selectedRange())")
            t6.balance(nil)
            check("balance outer", t6.selectedRange() == NSRange(location: 2, length: 9), "\(t6.selectedRange())")

            // Transforms on selection with undo
            let (doc7, t7) = try makeEditor("b\na\nc\n", name: "s.txt")
            t7.setSelectedRange(NSRange(location: 0, length: 0))
            step(t7) { t7.sortLinesAscending(nil) }
            check("sort whole document", t7.string == "a\nb\nc\n", t7.string.debugDescription)
            check("document marked edited", doc7.isDocumentEdited)
            t7.undoManager?.undo()
            check("undo sort", t7.string == "b\na\nc\n", t7.string.debugDescription)

            // Pasted CR/CRLF is normalized
            let (_, t8) = try makeEditor("")
            step(t8) { _ = t8.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x\r\ny\rz") }
            step(t8) { wait { t8.string == "x\ny\nz" } }
            check("paste normalizes line endings", t8.string == "x\ny\nz", t8.string.debugDescription)

            // Language detection + highlighting through temporary attributes
            let (doc9, t9) = try makeEditor("def f():\n    return \"s\"  # c\n", name: "p.py")
            check("language detected", doc9.language?.name == "Python", doc9.language?.name ?? "nil")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let lm = t9.layoutManager!
            let kw = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
            let str = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: 20, effectiveRange: nil) as? NSColor
            check("keyword coloured", kw == Theme.keyword)
            check("string coloured", str == Theme.string)
            check("storage untouched by highlighting", !doc9.isDocumentEdited)

            // Encoding failure surfaces as an error
            doc9.encoding = .ascii
            step(t9) { t9.replace(NSRange(location: 0, length: 0), with: "é") }
            check("unencodable text throws", (try? doc9.data(ofType: "public.plain-text")) == nil)
            try featureTests(check: { check($0, $1, $2) }, step: { tv, f in step(tv, f) }, makeEditor: { try makeEditor($0, name: $1) })
        } catch {
            check("setup", false, "\(error)")
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    /// Spins the run loop until `condition` holds or `timeout` passes.
    @discardableResult
    static func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }

    static func featureTests(check report: (String, Bool, String) -> Void,
                             step: (NSTextView, () -> Void) -> Void,
                             makeEditor: (String, String) throws -> (Document, EditorTextView)) throws {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report(name, ok, ok ? "" : detail()) }
        let fm = FileManager.default

        // Folding: hidden glyphs, layout, adjustment on edits, unfolding on selection
        let (fdoc, ft) = try makeEditor("func a() {\n    b()\n    c()\n}\nlet x = 1\n", "fold.swift")
        let fed = fdoc.editor
        wait { !fed.folds.available.isEmpty }
        check("fold regions detected", fed.folds.available.count == 1, "\(fed.folds.available)")
        if let f = fed.folds.available.first {
            fed.folds.fold(f.range)
            let lm = ft.layoutManager!
            lm.ensureLayout(for: ft.textContainer!)
            let ns = ft.string as NSString
            let bGlyph = lm.glyphIndexForCharacter(at: ns.range(of: "b()").location)
            check("folded glyphs are null", lm.propertyForGlyph(at: bGlyph) == .null)
            let first = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let letRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: ns.range(of: "let").location), effectiveRange: nil)
            check("folded lines collapse into one", abs(letRect.minY - first.maxY) < 0.5, "\(first) \(letRect)")
            check("gutter hides folded line numbers", fed.folds.isLineHidden(lineStart: ns.range(of: "    c()").location))
            step(ft) { ft.replace(NSRange(location: 0, length: 0), with: "// c\n", select: false) }
            check("fold shifts with edits above it", fed.folds.folded.first?.location == f.range.location + 5, "\(fed.folds.folded)")
            ft.setSelectedRange(NSRange(location: (ft.string as NSString).range(of: "c()").location, length: 0))
            check("selecting folded text unfolds", fed.folds.folded.isEmpty)
            fed.collapseAllFolds(nil)
            check("collapse all", fed.folds.folded.count == 1)
            fed.expandAllFolds(nil)
            check("expand all", fed.folds.folded.isEmpty)
        }

        // Completion
        let (_, ct) = try makeEditor("let counter = 1\ncounter += 2\ncou", "comp.swift")
        let partial = NSRange(location: (ct.string as NSString).length - 3, length: 3)
        let words = (ct.delegate as? EditorViewController)?.textView(ct, completions: [], forPartialWordRange: partial, indexOfSelectedItem: nil) ?? []
        check("completion offers document words", words.first == "counter", "\(words)")

        // Clippings
        let (_, kt) = try makeEditor("    x", "clip.swift")
        kt.setSelectedRange(NSRange(location: 4, length: 1))
        step(kt) { kt.insertClipping("if <#cond#> {\n    #SELECTION#\n}", fileName: "clip.swift") }
        check("clipping expands with indentation", kt.string == "    if <#cond#> {\n        x\n    }", kt.string.debugDescription)
        check("clipping selects first placeholder", (kt.string as NSString).substring(with: kt.selectedRange()) == "<#cond#>")
        kt.setSelectedRange(NSRange(location: 0, length: 0))
        kt.selectNextPlaceholder(nil)
        check("next placeholder", kt.selectedRange() == NSRange(location: 7, length: 8), "\(kt.selectedRange())")

        // Worksheet: persistent shell, output inserted below the command
        let (wdoc, wt) = try makeEditor("cd /usr\npwd\n", "sheet.worksheet")
        check("worksheet detected", wdoc.isWorksheet)
        wt.setSelectedRange(NSRange(location: 0, length: 0))
        wdoc.editor.runWorksheetCommand(nil)
        wait { wdoc.editor.validateMenuItem(NSMenuItem(title: "", action: #selector(EditorViewController.runWorksheetCommand(_:)), keyEquivalent: "")) }
        let pwdLine = (wt.string as NSString).range(of: "pwd")
        wt.setSelectedRange(NSRange(location: pwdLine.location, length: 0))
        wdoc.undoManager?.groupsByEvent = true
        wdoc.editor.runWorksheetCommand(nil)
        wait { wt.string.contains("pwd\n/usr\n") }
        check("worksheet keeps directory and inserts output", wt.string == "cd /usr\npwd\n/usr\n", wt.string.debugDescription)
        wdoc.stopShell()

        // Git gutter markers
        let repoDir = fm.temporaryDirectory.appendingPathComponent("quire-st-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoDir) }
        let tracked = repoDir.appendingPathComponent("t.txt")
        try "one\ntwo\nthree\n".write(to: tracked, atomically: true, encoding: .utf8)
        let git = GitRepository.gitPath
        _ = try ProcessRunner.check(git, ["init", "-q"], cwd: repoDir)
        _ = try ProcessRunner.check(git, ["-c", "user.name=T", "-c", "user.email=t@x", "add", "."], cwd: repoDir)
        _ = try ProcessRunner.check(git, ["-c", "user.name=T", "-c", "user.email=t@x", "commit", "-qm", "init"], cwd: repoDir)
        let gdoc = Document()
        gdoc.fileURL = tracked
        try gdoc.read(from: Data(contentsOf: tracked), ofType: "public.plain-text")
        let ged = gdoc.editor
        wait { ged.headText != nil }
        check("git HEAD loaded", ged.headText == "one\ntwo\nthree\n")
        ged.textView.replace(NSRange(location: 4, length: 3), with: "TWO", select: false)
        ged.textView.didChangeText()
        wait { !ged.ruler.gitMarkers.isEmpty }
        check("gutter marks modified line", ged.ruler.gitMarkers == [1: .modified], "\(ged.ruler.gitMarkers)")

        // Projects: embedded editors, switching, saving through the responder chain
        let projDir = repoDir.appendingPathComponent("proj")
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        let fa = projDir.appendingPathComponent("a.swift"), fb = projDir.appendingPathComponent("b.txt")
        try "let a = 1\n".write(to: fa, atomically: true, encoding: .utf8)
        try "bee\n".write(to: fb, atomically: true, encoding: .utf8)
        let project = ProjectDocument(items: [projDir])
        NSDocumentController.shared.addDocument(project)
        project.makeWindowControllers()
        project.showWindows()
        let pwc = project.windowController!
        pwc.openFile(fa)
        wait { pwc.currentDocument?.fileURL == fa }
        pwc.openFile(fb)
        wait { pwc.currentDocument?.fileURL == fb }
        check("project opens files in its window", pwc.documents.count == 2 && pwc.currentDocument?.fileURL == fb)
        let outline = pwc.sidebarOutline
        outline.layoutSubtreeIfNeeded()
        let labels = (0..<outline.numberOfRows).compactMap { (outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue }
        check("sidebar lists open documents and project items", labels.starts(with: ["Open Documents", "a.swift", "b.txt", "Project", "proj"]) && labels.suffix(2) == ["a.swift", "b.txt"], "\(labels)")
        check("sidebar is visible", outline.window != nil && !outline.isHiddenOrHasHiddenAncestor && outline.visibleRect.width > 100, "\(outline.visibleRect)")
        if let bdoc = pwc.currentDocument {
            check("embedded doc has no window of its own", bdoc.windowControllers.isEmpty)
            check("editor is in the responder chain", bdoc.editor.view.nextResponder === bdoc.editor)
            check("project is the editor host", NSApp.windows.contains { ($0.windowController as? EditorHost)?.activeEditor === bdoc.editor })
            bdoc.editor.textView.replace(NSRange(location: 0, length: 3), with: "BEE", select: false)
            bdoc.editor.saveDocument(nil)
            wait { (try? String(contentsOf: fb)) == "BEE\n" }
            check("save from embedded editor writes the file", (try? String(contentsOf: fb)) == "BEE\n")
            let model = String(decoding: try project.encodedModel(for: projDir.appendingPathComponent("p.quireproject")), as: UTF8.self)
            check("project remembers open documents", model.contains("\"a.swift\"") && model.contains("\"relative\" : \"b.txt\""), model)
            var closed = false
            pwc.requestClose(bdoc) { closed = $0 }
            wait { closed }
            check("closing a document in a project", closed && pwc.documents.count == 1 && pwc.currentDocument?.fileURL == fa)
        }
        project.close()

        // Language modules (the seeded Lua module must load cleanly)
        let errors = LanguageModulesLibrary.reload()
        check("language modules load", errors.isEmpty, "\(errors)")
        check("Lua module available", Languages.named("Lua").name == "Lua")
        check("Lua tokenizes", Tokenizer(language: Languages.named("Lua")).tokenize("local x = \"s\" -- c").map(\.kind) == [.keyword, .string, .comment])

        // Preview renders code, math and diagrams with the bundled libraries
        check("preview assets found", PreviewPane.assets != nil)
        let (mdoc, _) = try makeEditor("# T\n\n```swift\nlet x = 1\n```\n\n$e^x$\n\n```mermaid\ngraph LR\n  A --> B\n```\n\n```mermaid\nnot a diagram\n```\n\n```d2\nx -> y: hi\n```\n\n```dot\ndigraph { p -> q }\n```\n", "preview-test.md")
        mdoc.editor.showPreview(nil)
        // Poll the page until all four diagram blocks have become figures.
        var html = ""
        var asking = false
        let previewDone = Self.wait(20) {
            if !asking, let preview = mdoc.editor.preview {
                asking = true
                preview.whenRendered { html = $0 ?? ""; asking = false }
            }
            return html.components(separatedBy: "<figure").count == 5
        }
        check("preview highlights code", html.contains("hljs-keyword"), html)
        check("preview renders math", html.contains("class=\"katex\""), html)
        check("preview renders diagrams", previewDone && html.contains("<svg") && html.contains("figure class=\"diagram\""), html)
        check("preview shows diagram errors", html.contains("diagram-error-message"), html)
        check("preview renders D2", html.contains("data-engine=\"d2\"") && html.contains("d2-svg"), html)
        check("preview renders Graphviz", html.contains("data-engine=\"graphviz\"") && html.contains("class=\"graph\""), html)
        // The pane must actually paint: the snapshot has to contain more than the background.
        var image: NSImage?
        var snapped = false
        mdoc.editor.preview?.snapshot { image = $0; snapped = true }
        Self.wait(5) { snapped }
        let colours = image.flatMap { $0.tiffRepresentation }.flatMap(NSBitmapImageRep.init(data:)).map { rep -> Int in
            var seen = Set<UInt32>()
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
            return seen.count
        } ?? 0
        if let path = ProcessInfo.processInfo.environment["QUIRE_PREVIEW_PNG"], let tiff = image?.tiffRepresentation {
            try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        check("preview pane paints its page", colours > 20, "\(colours) colours, size \(image?.size ?? .zero)")
        let pane = mdoc.editor.preview?.view
        check("preview is a pane beside the text", pane?.superview != nil && pane?.window === mdoc.editor.textView.window
              && (pane?.frame.minX ?? 0) > mdoc.editor.scrollView.frame.maxX - 1, "\(pane?.frame ?? .zero)")
        mdoc.editor.togglePreview(nil)
        check("preview pane hides", mdoc.editor.preview == nil && pane?.superview == nil)
        mdoc.close()

        // Scroll sync: scrolling the editor brings the matching block to the top of the preview
        let long = (1...200).map { "Paragraph \($0) with enough words to be a line.\n" }.joined(separator: "\n")
        let (sdoc, stv) = try makeEditor("# Top\n\n" + long, "scroll-test.md")
        sdoc.editor.showPreview(nil)
        var loaded = false
        Self.wait(10) {
            if !loaded { sdoc.editor.preview?.whenRendered { if $0?.contains("Paragraph 200") == true { loaded = true } } }
            return loaded
        }
        let target = (stv.string as NSString).range(of: "Paragraph 120 ")
        stv.layoutManager?.ensureLayout(for: stv.textContainer!)
        let rect = stv.layoutManager!.boundingRect(forGlyphRange: stv.layoutManager!.glyphRange(forCharacterRange: target, actualCharacterRange: nil), in: stv.textContainer!)
        sdoc.editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + stv.textContainerOrigin.y))
        sdoc.editor.scrollView.reflectScrolledClipView(sdoc.editor.scrollView.contentView)
        var topText = ""
        var asked = false
        Self.wait(5) {
            if !asked {
                asked = true
                sdoc.editor.preview?.evaluate("""
                    const el = [...document.querySelectorAll("p")].find(p => p.getBoundingClientRect().bottom > 14);
                    return el ? el.textContent : "";
                    """) { topText = ($0 as? String) ?? ""; asked = false }
            }
            return topText.hasPrefix("Paragraph 120 ") || topText.hasPrefix("Paragraph 119 ")
        }
        check("preview scrolls with the editor", topText.hasPrefix("Paragraph 120 ") || topText.hasPrefix("Paragraph 119 "), topText)
        // …and the editor with the preview
        sdoc.editor.preview?.followRequiresPointer = false
        var scrolledPreview = false
        sdoc.editor.preview?.evaluate("""
            const el = [...document.querySelectorAll("p")].find(p => p.textContent.startsWith("Paragraph 40 "));
            await new Promise(r => setTimeout(r, 300));
            window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY - 12);
            return true;
            """) { _ in scrolledPreview = true }
        func editorTopText() -> String {
            guard let lm = stv.layoutManager, let tc = stv.textContainer else { return "" }
            var p = stv.visibleRect.origin
            p.y -= stv.textContainerOrigin.y
            let i = lm.characterIndexForGlyph(at: lm.glyphIndex(for: p, in: tc))
            let ns = stv.string as NSString
            return ns.substring(with: ns.lineRange(for: NSRange(location: min(i + 1, ns.length - 1), length: 0)))
        }
        Self.wait(5) { scrolledPreview && (editorTopText().hasPrefix("Paragraph 40 ") || editorTopText().hasPrefix("Paragraph 39 ")) }
        check("editor scrolls with the preview", editorTopText().hasPrefix("Paragraph 40 ") || editorTopText().hasPrefix("Paragraph 39 "), editorTopText())
        sdoc.editor.togglePreview(nil)
        sdoc.close()

        // Markdown formatting in the editor (Styled mode)
        let (stdoc, sttv) = try makeEditor("# Head\n\nplain **bold** *it* `code`\n\n- item\n", "styled-test.md")
        stdoc.editor.markdownMode = .styled
        func font(_ s: String, in tv: NSTextView) -> NSFont? {
            let r = (tv.string as NSString).range(of: s)
            return r.location == NSNotFound ? nil : tv.textStorage?.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        }
        let baseSize = Prefs.font.pointSize
        Self.wait(2) { (font("Head", in: sttv)?.pointSize ?? 0) > baseSize }
        check("styled: heading is larger and bold", (font("Head", in: sttv)?.pointSize ?? 0) > baseSize * 1.4
              && font("Head", in: sttv)?.fontDescriptor.symbolicTraits.contains(.bold) == true, "\(String(describing: font("Head", in: sttv)))")
        check("styled: strong is bold", font("bold", in: sttv)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        check("styled: emphasis is italic", font("it*", in: sttv)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        check("styled: plain text keeps the editor font", font("plain", in: sttv) == Prefs.font)
        check("styled: formatting doesn't edit the document", !stdoc.isDocumentEdited && stdoc.undoManager?.canUndo != true)
        let markerColor = sttv.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: (sttv.string as NSString).range(of: "**").location, effectiveRange: nil) as? NSColor
        check("styled: markers are dimmed", markerColor == Theme.markdownMarker)
        let bulletIndent = (sttv.textStorage?.attribute(.paragraphStyle, at: (sttv.string as NSString).range(of: "- item").location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
        check("styled: list items get a hanging indent", bulletIndent > 0, "\(bulletIndent)")
        // Typing restyles just the edited lines.
        sttv.setSelectedRange(NSRange(location: (sttv.string as NSString).length, length: 0))
        step(sttv) { sttv.insertText("\n## Added", replacementRange: sttv.selectedRange()) }
        Self.wait(2) { (font("Added", in: sttv)?.pointSize ?? 0) > baseSize }
        check("styled: new heading is styled as you type", (font("Added", in: sttv)?.pointSize ?? 0) > baseSize * 1.2)
        check("styled: an edit restyles only nearby lines", stdoc.editor.markdownStyler.lastRegion.location > 10, "\(stdoc.editor.markdownStyler.lastRegion)")
        sttv.undoManager?.undo()
        Self.wait(1) { !sttv.string.contains("Added") }
        check("styled: undo removes only the typing", sttv.string == "# Head\n\nplain **bold** *it* `code`\n\n- item\n", sttv.string.debugDescription)
        stdoc.editor.markdownMode = .source
        check("source mode: plain fonts again", font("Head", in: sttv) == Prefs.font && font("bold", in: sttv) == Prefs.font)
        stdoc.editor.markdownMode = .styled
        Self.wait(2) { (font("Head", in: sttv)?.pointSize ?? 0) > baseSize }
        // A 200 KB document: each keystroke's main-thread work stays small.
        let sample = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../docs/preview-sample.md").standardized, encoding: .utf8)) ?? "# x\n\ntext\n"
        var big = ""
        while big.utf8.count < 200_000 { big += sample + "\n\n" }
        sttv.string = big
        stdoc.editor.markdownStyler.restyleAll()
        Self.wait(10) { stdoc.editor.markdownStyler.spans.count > 1000 && !stdoc.editor.markdownStyler.isStylingInBackground }
        // Typing into prose: the common case.
        var worst: TimeInterval = 0
        let bigText = (sttv.string as NSString)
        var searchFrom = 0
        for _ in 0..<5 {
            let hit = bigText.range(of: "renders", range: NSRange(location: searchFrom, length: bigText.length - searchFrom))
            guard hit.location != NSNotFound else { break }
            searchFrom = NSMaxRange(hit) + 20_000
            sttv.setSelectedRange(NSRange(location: hit.location + 3, length: 0))
            step(sttv) { sttv.insertText("x", replacementRange: sttv.selectedRange()) }
            let before = stdoc.editor.markdownStyler.lastPassDuration
            Self.wait(2) { stdoc.editor.markdownStyler.lastPassDuration != before }
            worst = max(worst, stdoc.editor.markdownStyler.lastPassDuration)
        }
        print("styled: worst prose keystroke on 200 KB: \(String(format: "%.1f", worst * 1000)) ms")
        // Debug builds are about twice as slow as release, where the target is 8 ms.
        #if DEBUG
        let budget = 0.020
        #else
        let budget = 0.008
        #endif
        check("styled: typing prose in a 200 KB file stays within \(Int(budget * 1000)) ms a keystroke", worst < budget, "\(worst * 1000) ms")
        // Typing while a big file is still being formatted keeps the background work going.
        stdoc.editor.markdownStyler.restyleAll()
        Self.wait(5) { stdoc.editor.markdownStyler.isStylingInBackground }
        let early = (sttv.string as NSString).range(of: "renders").location
        sttv.setSelectedRange(NSRange(location: early + 2, length: 0))
        let beforeEarly = stdoc.editor.markdownStyler.lastPassDuration
        step(sttv) { sttv.insertText("y", replacementRange: sttv.selectedRange()) }
        Self.wait(2) { stdoc.editor.markdownStyler.lastPassDuration != beforeEarly }
        let earlyCost = stdoc.editor.markdownStyler.lastPassDuration
        Self.wait(10) { !stdoc.editor.markdownStyler.isStylingInBackground }
        let lastHeading = (sttv.string as NSString).range(of: "## Code", options: .backwards).location
        let lastFont = sttv.textStorage?.attribute(.font, at: lastHeading + 3, effectiveRange: nil) as? NSFont
        check("styled: typing during background formatting stays cheap and the rest still gets formatted",
              earlyCost < budget && (lastFont?.pointSize ?? 0) > Prefs.font.pointSize, "\(Int(earlyCost * 1000)) ms, \(String(describing: lastFont))")
        // Breaking a $$ block changes everything after it: the whole rest is restyled.
        let dollars = (sttv.string as NSString).range(of: "$$\n\nPrices")
        sttv.setSelectedRange(NSRange(location: dollars.location + 2, length: 0))
        step(sttv) { sttv.insertText("x", replacementRange: sttv.selectedRange()) }
        let before = stdoc.editor.markdownStyler.lastPassDuration
        Self.wait(2) { stdoc.editor.markdownStyler.lastPassDuration != before }
        print("styled: structural edit restyling \(stdoc.editor.markdownStyler.lastRegion.length) characters: \(Int(stdoc.editor.markdownStyler.lastPassDuration * 1000)) ms")
        stdoc.close()

        // Live Preview: markers hidden away from the cursor
        let liveText = "# Head\n\nSome **bold** and [a link](https://example.com/x).\n\n- [ ] task\n\n***\n\n```\ncode\n```\n\nend"
        let (lvDoc, lvtv) = try makeEditor(liveText, "live-test.md")
        lvDoc.editor.markdownMode = .live
        let lvns = lvtv.string as NSString
        lvtv.setSelectedRange(NSRange(location: lvns.length, length: 0))
        let lvlm = lvtv.layoutManager as! InvisiblesLayoutManager
        func glyphProperty(_ s: String, offset: Int = 0) -> NSLayoutManager.GlyphProperty? {
            let r = (lvtv.string as NSString).range(of: s)
            guard r.location != NSNotFound else { return nil }
            lvlm.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: (lvtv.string as NSString).length))
            return lvlm.propertyForGlyph(at: lvlm.glyphIndexForCharacter(at: r.location + offset))
        }
        Self.wait(2) { !lvDoc.editor.folds.markup.isEmpty }
        check("live: heading and emphasis markers are hidden", glyphProperty("# Head") == .null && glyphProperty("**bold") == .null)
        check("live: link URL is hidden, text shown", glyphProperty("](https") == .null && glyphProperty("a link") != .null)
        let styles = lvDoc.editor.folds.markup.map(\.style)
        check("live: bullet, checkbox and rule widgets", styles.contains(.bullet) && styles.contains(.checkbox(checked: false)) && styles.contains(.rule), "\(styles)")
        lvtv.setSelectedRange(NSRange(location: lvns.range(of: "bold").location, length: 0))
        check("live: markers reappear where the cursor is", glyphProperty("**bold") != .null && glyphProperty("# Head") == .null)
        check("live: ⌘-click finds the link", lvtv.linkResolver?(lvns.range(of: "a link").location + 2)?.absoluteString == "https://example.com/x")
        lvtv.setSelectedRange(NSRange(location: lvns.length, length: 0))
        if let box = lvDoc.editor.folds.markup.first(where: { if case .checkbox = $0.style { return true }; return false }) {
            lvlm.ensureLayout(for: lvtv.textContainer!)
            let r = lvlm.checkboxRect(for: box)
            let p = lvtv.convert(NSPoint(x: r.midX + lvtv.textContainerOrigin.x, y: r.midY + lvtv.textContainerOrigin.y), to: nil)
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: lvtv.window?.windowNumber ?? 0,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            var clicked = false
            step(lvtv) { clicked = lvtv.handleMarkdownClick(click) }
            check("live: clicking a checkbox ticks the task", clicked && lvtv.string.contains("- [x] task"), lvtv.string)
        } else {
            check("live: clicking a checkbox ticks the task", false, "no checkbox")
        }
        lvtv.setSelectedRange(NSRange(location: (lvtv.string as NSString).length, length: 0))
        lvlm.ensureLayout(for: lvtv.textContainer!)
        // The fence line's fragment is the one holding its line break.
        let fence = lvlm.lineFragmentRect(forGlyphAt: lvlm.glyphIndexForCharacter(at: (lvtv.string as NSString).range(of: "```").location + 3), effectiveRange: nil)
        let codeLine = lvlm.lineFragmentRect(forGlyphAt: lvlm.glyphIndexForCharacter(at: (lvtv.string as NSString).range(of: "code").location), effectiveRange: nil)
        check("live: hidden code fence lines collapse", fence.height < codeLine.height * 0.5, "\(fence.height) vs \(codeLine.height)")
        lvDoc.editor.markdownMode = .styled
        check("styled: no hidden markers", lvDoc.editor.folds.markup.isEmpty && glyphProperty("# Head") != .null)
        lvDoc.close()

        // GitHub alerts and inline code in Live Preview
        let (alDoc, altv) = try makeEditor("> [!WARNING]\n> Careful with `code`.\n\nend", "alerts.md")
        alDoc.editor.markdownMode = .live
        altv.setSelectedRange(NSRange(location: (altv.string as NSString).length, length: 0))
        let allm = altv.layoutManager as! InvisiblesLayoutManager
        let titleAt = (altv.string as NSString).range(of: "WARNING").location
        let titleColor = allm.temporaryAttribute(.foregroundColor, atCharacterIndex: titleAt, effectiveRange: nil) as? NSColor
        let bar = allm.markdownBlocks.first { $0.kind == .quote }
        check("live: alerts get a coloured bar and label", titleColor == Theme.markdownAlert("warning") && bar?.color == Theme.markdownAlert("warning"),
              "\(String(describing: titleColor)) \(String(describing: bar))")
        allm.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: (altv.string as NSString).length))
        check("live: alert brackets hidden", allm.propertyForGlyph(at: allm.glyphIndexForCharacter(at: titleAt - 1)) == .null)
        let codeAt = (altv.string as NSString).range(of: "code").location
        check("live: inline code background is drawn per line, not as an attribute",
              allm.inlineCode.count == 1 && allm.temporaryAttribute(.backgroundColor, atCharacterIndex: codeAt, effectiveRange: nil) == nil)
        alDoc.close()

        // Live Preview widgets: math, diagrams and images drawn in place
        let wDir = fm.temporaryDirectory.appendingPathComponent("quire-widgets-\(UUID().uuidString)")
        try fm.createDirectory(at: wDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: wDir) }
        let wpng = NSImage(size: NSSize(width: 60, height: 30), flipped: false) { r in NSColor.orange.setFill(); r.fill(); return true }
        try NSBitmapImageRep(data: wpng.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: wDir.appendingPathComponent("w.png"))
        let (wDoc, wtv) = try makeEditor("Math $a^2$ here.\n\n```mermaid\ngraph LR\n  A --> B\n```\n\n```d2\nx -> y\n```\n\n```graphviz\ndigraph { p -> q }\n```\n\n![pic](w.png)\n\nend", "widgets.md")
        wDoc.fileURL = wDir.appendingPathComponent("widgets.md")
        wDoc.editor.markdownMode = .live
        wtv.setSelectedRange(NSRange(location: (wtv.string as NSString).length, length: 0))
        wDoc.editor.markdownStyler.updateLive(selection: wtv.selectedRange())
        func widgetCount() -> Int { wDoc.editor.folds.markup.filter { if case .widget = $0.style { return true }; return false }.count }
        Self.wait(30) { widgetCount() == 5 }
        check("live: math, diagrams and image become pictures", widgetCount() == 5, "\(wDoc.editor.folds.markup.map(\.style))")
        wtv.setSelectedRange(NSRange(location: 2, length: 0))
        check("live: a picture turns back into source at the cursor", widgetCount() == 4)
        wDoc.close()

        // Tables: Tab formats and moves to the next cell
        let (tDoc, ttv) = try makeEditor("| a | b |\n|---|---|\n| 1 | 2 |", "table.md")
        ttv.setSelectedRange(NSRange(location: (ttv.string as NSString).range(of: "1").location, length: 0))
        step(ttv) { ttv.insertTab(nil) }
        check("md: Tab in a table pads the columns and moves on", ttv.string == "| a   | b   |\n| --- | --- |\n| 1   | 2   |"
              && (ttv.string as NSString).substring(with: ttv.selectedRange()) == "2", ttv.string)
        tDoc.close()

        // Markdown editing behaviours
        let (edDoc, etv) = try makeEditor("- one", "edit-test.md")
        func caretAtEnd() { etv.setSelectedRange(NSRange(location: (etv.string as NSString).length, length: 0)) }
        caretAtEnd()
        step(etv) { etv.insertNewline(nil) }
        check("md: Return continues a list", etv.string == "- one\n- ", etv.string.debugDescription)
        step(etv) { etv.insertNewline(nil) }
        check("md: Return on an empty item ends the list", etv.string == "- one\n", etv.string.debugDescription)
        etv.string = "1. a\n2. b\n3. c"
        etv.setSelectedRange(NSRange(location: 8, length: 0))   // in "2. b"
        step(etv) { etv.insertTab(nil) }
        check("md: Tab nests an item, restarting and renumbering", etv.string == "1. a\n    1. b\n2. c", etv.string.debugDescription)
        step(etv) { etv.insertBacktab(nil) }
        check("md: Shift-Tab moves it back and renumbers", etv.string == "1. a\n2. b\n3. c", etv.string.debugDescription)
        etv.string = "make this bold"
        etv.window?.makeFirstResponder(etv)
        etv.setSelectedRange(NSRange(location: 5, length: 4))
        let cmdB = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: etv.window?.windowNumber ?? 0,
                                    context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!
        var handled = false
        step(etv) { handled = etv.performKeyEquivalent(with: cmdB) }
        check("md: ⌘B makes bold", handled && etv.string == "make **this** bold", etv.string)
        step(etv) { _ = etv.performKeyEquivalent(with: cmdB) }
        check("md: ⌘B again removes it", etv.string == "make this bold", etv.string)
        etv.setSelectedRange(NSRange(location: 5, length: 4))
        step(etv) { etv.insertText("`", replacementRange: etv.selectedRange()) }
        check("md: typing ` around a selection wraps it", etv.string == "make `this` bold" && etv.selectedRange() == NSRange(location: 6, length: 4), etv.string)
        let pb = NSPasteboard(name: NSPasteboard.Name("quire-selftest-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("https://example.com/x", forType: .string)
        etv.setSelectedRange(NSRange(location: 0, length: 4))
        step(etv) { _ = etv.readSelection(from: pb, type: .string) }
        check("md: pasting a URL over a selection makes a link", etv.string.hasPrefix("[make](https://example.com/x)"), etv.string)
        // Images: pasted image data and dropped files go into assets/ next to the document
        let docDir = fm.temporaryDirectory.appendingPathComponent("quire-assets-\(UUID().uuidString)")
        try fm.createDirectory(at: docDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: docDir) }
        edDoc.fileURL = docDir.appendingPathComponent("notes.md")
        etv.string = ""
        let dot = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { r in NSColor.blue.setFill(); r.fill(); return true }
        pb.clearContents()
        pb.setData(NSBitmapImageRep(data: dot.tiffRepresentation!)!.representation(using: .png, properties: [:]), forType: .png)
        step(etv) { _ = etv.readSelection(from: pb, type: .png) }
        let pasted = (try? fm.contentsOfDirectory(atPath: docDir.appendingPathComponent("assets").path)) ?? []
        check("md: pasted image saved in assets/ and linked", pasted.count == 1 && etv.string == "![](assets/\(pasted.first ?? "?"))", "\(pasted) \(etv.string)")
        let savedFolder = Prefs.markdownImagesFolder
        Prefs.markdownImagesFolder = "pics/notes"
        etv.string = ""
        step(etv) { _ = etv.readSelection(from: pb, type: .png) }
        let inPics = (try? fm.contentsOfDirectory(atPath: docDir.appendingPathComponent("pics/notes").path)) ?? []
        check("md: images go to the chosen folder", inPics.count == 1 && etv.string == "![](pics/notes/\(inPics.first ?? "?"))", etv.string)
        Prefs.markdownImagesFolder = savedFolder
        let outside = fm.temporaryDirectory.appendingPathComponent("quire-drop-\(UUID().uuidString).png")
        try NSBitmapImageRep(data: dot.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: outside)
        defer { try? fm.removeItem(at: outside) }
        etv.string = ""
        pb.clearContents()
        pb.writeObjects([outside as NSURL])
        step(etv) { _ = etv.readSelection(from: pb, type: .fileURL) }
        let name = outside.deletingPathExtension().lastPathComponent
        check("md: dropped image copied into assets/ and linked", etv.string == "![\(name)](assets/\(name).png)"
              && fm.fileExists(atPath: docDir.appendingPathComponent("assets/\(name).png").path), etv.string)
        pb.releaseGlobally()
        edDoc.editor.updateInfoForTests()
        Self.wait(3) { edDoc.editor.markdownWordCount != nil }
        check("md: word count in the status bar", edDoc.editor.markdownWordCount != nil)
        edDoc.close()

        // Export: self-contained HTML and paginated PDF
        let exportDir = fm.temporaryDirectory.appendingPathComponent("quire-export-\(UUID().uuidString)")
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: exportDir) }
        let png = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        try NSBitmapImageRep(data: png.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: exportDir.appendingPathComponent("dot.png"))
        let exportSource = """
            ---
            title: Export Test
            author: Quire Self Test
            ---
            # Introduction

            Some **bold** text, math $e^{i\\pi} + 1 = 0$ and an image ![dot](dot.png).

            ```swift
            let answer = 42
            ```

            ## Diagram

            ```mermaid
            graph LR
              A --> B
            ```

            ```d2
            source -> export
            ```

            > [!TIP]
            > Alerts survive export.

            ## Long section

            """ + (1...60).map { "Paragraph \($0) of filler text so the PDF runs onto several pages." }.joined(separator: "\n\n")
        let mdURL = exportDir.appendingPathComponent("export-test.md")
        try exportSource.write(to: mdURL, atomically: true, encoding: .utf8)
        var exportOptions = MarkdownExportOptions()
        exportOptions.tableOfContents = true
        exportOptions.titlePage = true
        var htmlError: Error?
        var htmlDone = false
        let htmlURL = exportDir.appendingPathComponent("out.html")
        MarkdownExporter(markdown: exportSource, fileURL: mdURL, name: "export-test.md", options: exportOptions)
            .exportHTML(to: htmlURL) { htmlError = $0; htmlDone = true }
        Self.wait(60) { htmlDone }
        let exported = (try? String(contentsOf: htmlURL, encoding: .utf8)) ?? ""
        check("HTML export finishes", htmlDone && htmlError == nil, "\(String(describing: htmlError))")
        check("HTML export has no scripts or external links", !exported.isEmpty && !exported.contains("<script") && !exported.contains("<link ")
              && !exported.contains("file://"), String(exported.prefix(400)))
        check("HTML export embeds diagram, math, fonts, code, images",
              exported.contains("<svg") && exported.contains("d2-svg") && exported.contains("class=\"katex") && exported.contains("data:font/woff2")
              && exported.contains("hljs-keyword") && exported.contains("data:image/png;base64,"), "")
        check("HTML export has title, contents and alert", exported.contains("<title>Export Test</title>") && exported.contains("<nav class=\"toc\">")
              && exported.contains("markdown-alert-tip") && !exported.contains("class=\"front-matter\""),
              "title \(exported.contains("<title>Export Test</title>")) toc \(exported.contains("<nav class=\"toc\">")) alert \(exported.contains("markdown-alert-tip")) fm \(exported.contains("front-matter"))")
        check("HTML export is light only", !exported.contains("prefers-color-scheme: dark"), "")

        var pdfError: Error?
        var pdfDone = false
        let pdfURL = exportDir.appendingPathComponent("out.pdf")
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 595, height: 842)   // A4
        MarkdownExporter(markdown: exportSource, fileURL: mdURL, name: "export-test.md", options: exportOptions)
            .exportPDF(to: pdfURL, printInfo: printInfo) { pdfError = $0; pdfDone = true }
        Self.wait(60) { pdfDone }
        let pdf = PDFDocument(url: pdfURL)
        let pdfText = pdf?.string ?? ""
        check("PDF export finishes", pdfDone && pdfError == nil, "\(String(describing: pdfError))")
        check("PDF export is paginated", (pdf?.pageCount ?? 0) >= 4, "\(pdf?.pageCount ?? 0) pages")
        check("PDF has the document text", pdfText.contains("Introduction") && pdfText.contains("Paragraph 60"), String(pdfText.prefix(300)))
        check("PDF title page comes first", pdf?.page(at: 0)?.string?.contains("Quire Self Test") == true
              && pdf?.page(at: 0)?.string?.contains("Paragraph 1 ") != true, pdf?.page(at: 0)?.string ?? "")
        check("PDF metadata", (pdf?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) == "Export Test"
              && (pdf?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String) == "Quire Self Test",
              "\(pdf?.documentAttributes ?? [:])")
        let pageSize = pdf?.page(at: 1)?.bounds(for: .mediaBox).size ?? .zero
        check("PDF uses the page setup paper size", abs(pageSize.width - 595) < 2 && abs(pageSize.height - 842) < 2, "\(pageSize)")
        let numbered = (1..<(pdf?.pageCount ?? 1)).compactMap { pdf?.page(at: $0)?.annotations.first { $0.type == "FreeText" }?.contents }
        check("PDF has page numbers, not on the title page", pdf?.page(at: 0)?.annotations.contains { $0.type == "FreeText" } == false
              && numbered.first == "1 / \((pdf?.pageCount ?? 1) - 1)" && numbered.count == (pdf?.pageCount ?? 1) - 1, "\(numbered)")

        // Themes: dark, and light/dark following the reader's system
        func exportHTML(_ theme: MarkdownExportOptions.Theme) -> String {
            var o = MarkdownExportOptions()
            o.theme = theme
            var finished = false
            let url = exportDir.appendingPathComponent("theme-\(theme.rawValue).html")
            MarkdownExporter(markdown: exportSource, fileURL: mdURL, name: "export-test.md", options: o).exportHTML(to: url) { _ in finished = true }
            Self.wait(60) { finished }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        let darkPage = exportHTML(.dark)
        check("HTML export in dark colours", darkPage.contains("content=\"dark\"") && !darkPage.contains("prefers-color-scheme") && darkPage.contains("<svg"), "")
        let autoPage = exportHTML(.auto)
        check("HTML export following the reader's system", autoPage.contains("only-light diagram") && autoPage.contains("only-dark diagram")
              && autoPage.contains("quire-diagram-dark-") && autoPage.contains("prefers-color-scheme: dark"), "")

        // Link addresses printed after links
        var linkOptions = MarkdownExportOptions()
        linkOptions.linkAddresses = true
        var linkDone = false
        let linkPDF = exportDir.appendingPathComponent("links.pdf")
        MarkdownExporter(markdown: "See [the site](https://example.com/page).", fileURL: mdURL, name: "links.md", options: linkOptions)
            .exportPDF(to: linkPDF, printInfo: printInfo) { _ in linkDone = true }
        Self.wait(60) { linkDone }
        let linkText = PDFDocument(url: linkPDF)?.string ?? ""
        check("PDF prints link addresses when asked", linkText.contains("example.com/page"), linkText)

        if let path = ProcessInfo.processInfo.environment["QUIRE_EXPORT_DIR"] {
            try? fm.copyItem(at: htmlURL, to: URL(fileURLWithPath: path).appendingPathComponent("selftest.html"))
            try? fm.copyItem(at: pdfURL, to: URL(fileURLWithPath: path).appendingPathComponent("selftest.pdf"))
        }

        // Appearance: Light / Dark / System, applied to the editor and the preview
        if let app = NSApp.delegate as? AppDelegate {
            let saved = Prefs.appearance
            let (adoc, _) = try makeEditor("# Theme\n", "appearance-test.md")
            adoc.editor.showPreview(nil)
            func previewBrightness() -> CGFloat? {
                var html = "", asking = false
                Self.wait(10) {
                    if !asking { asking = true; adoc.editor.preview?.whenRendered { html = $0 ?? ""; asking = false } }
                    return html.contains("Theme")
                }
                var image: NSImage?, done = false
                adoc.editor.preview?.snapshot { image = $0; done = true }
                Self.wait(5) { done }
                guard let rep = image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
                      let c = rep.colorAt(x: 4, y: rep.pixelsHigh - 4)?.usingColorSpace(.sRGB) else { return nil }
                return (c.redComponent + c.greenComponent + c.blueComponent) / 3
            }
            func editorIsDark() -> Bool { adoc.editor.textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

            Prefs.appearance = .dark
            check("dark appearance reaches the editor", editorIsDark())
            check("dark appearance reaches the preview", (previewBrightness() ?? 1) < 0.3)
            app.toggleAppearance(nil)
            check("switch light/dark flips to light", Prefs.appearance == .light && !editorIsDark())
            check("light appearance reaches the preview", (previewBrightness() ?? 0) > 0.8)
            Prefs.appearance = .system
            check("system setting follows macOS", NSApp.appearance == nil)
            Prefs.appearance = saved
            adoc.editor.hidePreview()
            adoc.close()
        }

        // File ▸ Open Path: escaped spaces and a line:column suffix
        if let app = NSApp.delegate as? AppDelegate {
            let dir = fm.temporaryDirectory.appendingPathComponent("quire open path")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("my notes.md")
            try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
            let typed = file.path.replacingOccurrences(of: " ", with: "\\ ") + ":3:2"
            check("open path accepts an escaped path", app.open(path: typed, base: dir) == nil)
            var opened: Document?
            Self.wait { opened = NSDocumentController.shared.documents.first { $0.fileURL?.standardizedFileURL == file.standardizedFileURL } as? Document
                        return opened?.editor.textView.selectedRange().location == 9 }
            check("open path jumps to line and column", opened?.editor.textView.selectedRange().location == 9,
                  "\(opened?.editor.textView.selectedRange() ?? NSRange())")
            check("open path reports missing files", app.open(path: "/no/such/file.md", base: dir)?.contains("/no/such/file.md") == true)
            opened?.close()
        }

        // SSH askpass wiring
        check("ssh uses our askpass", RemoteFiles.client.environment["SSH_ASKPASS"] == Bundle.main.executablePath)

        // AppleScript (only meaningful inside the app bundle)
        if Bundle.main.bundleIdentifier == "local.quire.editor" {
            let (sdoc, _) = try makeEditor("aab a", "script-test.txt")
            NSDocumentController.shared.addDocument(sdoc)
            sdoc.undoManager?.groupsByEvent = true   // as for any real document
            let source = """
            tell application id "local.quire.editor"
                set d to document "script-test.txt"
                set n to replace "a+" with "<&>" in d using grep true
                set out to run worksheet command "echo hi" in d
                return (n as text) & "|" & (text of d) & "|" & (source language of d) & "|" & (line count of d) & "|" & out
            end tell
            """
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
            check("AppleScript dictionary works", result == "2|<aa>b <a>|Plain Text|1|hi\n", "\(result ?? "nil") \(err ?? [:])")
            sdoc.stopShell()

            // Export finishes asynchronously: the script returns at once and the file appears later.
            let (edoc, _) = try makeEditor("# Scripted\n\nExported by **AppleScript**.\n", "script-export.md")
            NSDocumentController.shared.addDocument(edoc)
            let out = fm.temporaryDirectory.appendingPathComponent("quire-script-\(UUID().uuidString).pdf")
            var exportErr: NSDictionary?
            NSAppleScript(source: "tell application id \"local.quire.editor\" to export document \"script-export.md\" as PDF to POSIX file \"\(out.path)\"")?
                .executeAndReturnError(&exportErr)
            var scripted: PDFDocument?
            Self.wait(60) { scripted = PDFDocument(url: out); return scripted?.string?.contains("AppleScript") == true }
            check("AppleScript exports PDF", scripted?.string?.contains("Exported by AppleScript") == true, "\(exportErr ?? [:])")
            try? fm.removeItem(at: out)
            edoc.close()
        } else {
            print("SKIP AppleScript (not running from the app bundle)")
        }
    }
}
