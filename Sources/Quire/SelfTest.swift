import AppKit
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
        let (mdoc, _) = try makeEditor("# T\n\n```swift\nlet x = 1\n```\n\n$e^x$\n\n```mermaid\ngraph LR\n  A --> B\n```\n\n```mermaid\nnot a diagram\n```\n", "preview-test.md")
        mdoc.editor.showPreview(nil)
        // Poll the page until both diagram blocks have become figures.
        var html = ""
        var asking = false
        let previewDone = Self.wait(20) {
            if !asking, let preview = mdoc.editor.preview {
                asking = true
                preview.whenRendered { html = $0 ?? ""; asking = false }
            }
            return html.components(separatedBy: "<figure").count == 3
        }
        check("preview highlights code", html.contains("hljs-keyword"), html)
        check("preview renders math", html.contains("class=\"katex\""), html)
        check("preview renders diagrams", previewDone && html.contains("<svg") && html.contains("figure class=\"diagram\""), html)
        check("preview shows diagram errors", html.contains("diagram-error-message"), html)
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
        } else {
            print("SKIP AppleScript (not running from the app bundle)")
        }
    }
}
