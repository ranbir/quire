import AppKit
import QuireCore

final class EditorTextView: NSTextView {
    var language: Language = Languages.plainText
    var tabWidth = 4
    var expandTabs = true
    var autoIndent = true
    var showPageGuide = true
    var pageGuideColumn = 80
    var highlightCurrentLine = true
    var autoComplete = false
    weak var foldManager: FoldManager?
    private var completionWork: DispatchWorkItem?

    var indentUnit: String { expandTabs ? String(repeating: " ", count: tabWidth) : "\t" }
    private var ns: NSString { string as NSString }

    var charWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: font ?? Prefs.font]).width
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if highlightCurrentLine, selectedRange().length == 0, let r = currentLineRect() {
            Theme.currentLine.setFill()
            NSRect(x: rect.minX, y: r.minY, width: rect.width, height: r.height).fill()
        }
        if showPageGuide {
            let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) + charWidth * CGFloat(pageGuideColumn)
            Theme.pageGuide.setFill()
            NSRect(x: floor(x), y: rect.minY, width: 1, height: rect.height).fill()
        }
    }

    private func currentLineRect() -> NSRect? {
        guard let lm = layoutManager else { return nil }
        let loc = selectedRange().location
        var r: NSRect
        if loc >= ns.length && (ns.length == 0 || ns.character(at: ns.length - 1) == 10) {
            r = lm.extraLineFragmentRect
            if r.isEmpty { return nil }
        } else {
            let g = lm.glyphIndexForCharacter(at: min(loc, max(0, ns.length - 1)))
            r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        }
        r.origin.y += textContainerOrigin.y
        return r
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        // Moving the selection into folded text opens the fold.
        if !stillSelecting, let fm = foldManager, !fm.folded.isEmpty {
            for v in ranges {
                let r = v.rangeValue
                for edge in [r.location, NSMaxRange(r)] where fm.fold(containing: edge).map({ edge > $0.location }) == true {
                    fm.unfold(intersecting: NSRange(location: edge, length: 0))
                }
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if highlightCurrentLine { setNeedsDisplay(visibleRect, avoidAdditionalLayout: true) }
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // Clicking a fold capsule opens the fold.
        if let fm = foldManager, !fm.folded.isEmpty, let lm = layoutManager as? InvisiblesLayoutManager {
            var p = convert(event.locationInWindow, from: nil)
            p.x -= textContainerOrigin.x; p.y -= textContainerOrigin.y
            if let hit = fm.folded.first(where: { lm.capsuleRect(for: $0).insetBy(dx: -2, dy: -2).contains(p) }) {
                fm.unfold(hit)
                setSelectedRange(NSRange(location: hit.location, length: 0))
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Completion

    /// Called after each edit; pops up completions when auto-complete is on.
    func textDidChangeForCompletion() {
        completionWork?.cancel()
        guard autoComplete, selectedRange().length == 0, window?.firstResponder === self else { return }
        let loc = selectedRange().location
        var start = loc
        while start > 0, let u = UnicodeScalar(ns.character(at: start - 1)), CharacterSet.alphanumerics.contains(u) || u == "_" { start -= 1 }
        guard loc - start >= 3, let last = UnicodeScalar(ns.character(at: loc - 1)), CharacterSet.alphanumerics.contains(last) || last == "_" else { return }
        let length = ns.length
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.selectedRange().location == loc, self.ns.length == length else { return }
            self.complete(nil)
        }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: Clippings & placeholders

    func insertClipping(_ template: String, fileName: String) {
        let sel = selectedRange()
        let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let indent = String(ns.substring(with: NSRange(location: lineStart, length: sel.location - lineStart)).prefix { $0 == " " || $0 == "\t" })
        let ctx = ClippingContext(selection: ns.substring(with: sel), indent: indent, fileName: fileName,
                                  clipboard: NSPasteboard.general.string(forType: .string) ?? "")
        let (text, select) = Clippings.expand(template, context: ctx)
        replace(sel, with: text, select: false)
        if let select {
            setSelectedRange(NSRange(location: sel.location + select.location, length: select.length))
        } else {
            setSelectedRange(NSRange(location: sel.location + (text as NSString).length, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    @objc func selectNextPlaceholder(_ sender: Any?) {
        guard let r = Clippings.nextPlaceholder(in: string, after: NSMaxRange(selectedRange())) else { NSSound.beep(); return }
        setSelectedRange(r); scrollRangeToVisible(r)
    }

    @objc func selectPreviousPlaceholder(_ sender: Any?) {
        guard let r = Clippings.previousPlaceholder(in: string, before: selectedRange().location) else { NSSound.beep(); return }
        setSelectedRange(r); scrollRangeToVisible(r)
    }

    // MARK: Typing behaviour

    override func insertTab(_ sender: Any?) {
        if selectedRange().length > 0 && ns.substring(with: selectedRange()).contains("\n") {
            shiftRight(sender); return
        }
        guard expandTabs else { super.insertTab(sender); return }
        let loc = selectedRange().location
        let lineStart = ns.lineRange(for: NSRange(location: loc, length: 0)).location
        let col = TextTransforms.detab(ns.substring(with: NSRange(location: lineStart, length: loc - lineStart)), tabWidth: tabWidth).count
        insertText(String(repeating: " ", count: tabWidth - col % tabWidth), replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) { shiftLeft(sender) }

    override func insertNewline(_ sender: Any?) {
        guard autoIndent else { super.insertNewline(sender); return }
        let sel = selectedRange()
        let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
        var indent = String(before.prefix { $0 == " " || $0 == "\t" })
        if let last = before.trimmingCharacters(in: .whitespaces).last, language.indentAfter.contains(last) {
            indent += indentUnit
        }
        insertText("\n" + indent, replacementRange: sel)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Close-brace outdent: typing "}" on a whitespace-only line.
        if autoIndent, let s = string as? String, s == "}" || s == "]" || s == ")" {
            let sel = selectedRange()
            let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
            let before = ns.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
            if !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }), sel.length == 0 {
                let outdented = TextTransforms.shiftLeft(before, tabWidth: tabWidth)
                super.insertText(outdented + s, replacementRange: NSRange(location: lineStart, length: before.utf16.count))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Normalises pasted/dropped CR and CRLF line breaks to LF.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let s = replacementString, (s as NSString).range(of: "\r").location != NSNotFound {
            let fixed = TextCodec.normalizeLineEndings(s)
            DispatchQueue.main.async { [weak self] in
                self?.replace(affectedCharRange, with: fixed, select: false)
                self?.setSelectedRange(NSRange(location: affectedCharRange.location + (fixed as NSString).length, length: 0))
            }
            return false
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    // MARK: Editing primitives

    /// Undoable replacement.
    func replace(_ range: NSRange, with s: String, select: Bool = true) {
        guard super.shouldChangeText(in: range, replacementString: s), let storage = textStorage else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: s, attributes: typingAttributes))
        didChangeText()
        if select { setSelectedRange(NSRange(location: range.location, length: (s as NSString).length)) }
    }

    /// Selection expanded to whole lines; the whole document when nothing is selected and `wholeIfEmpty`.
    func targetLineRange(wholeIfEmpty: Bool) -> NSRange {
        let sel = selectedRange()
        if sel.length == 0 && wholeIfEmpty { return NSRange(location: 0, length: ns.length) }
        var r = ns.lineRange(for: sel)
        // A selection ending exactly at a line start shouldn't pull in the next line.
        if sel.length > 0, NSMaxRange(sel) > 0, NSMaxRange(sel) < NSMaxRange(r), ns.character(at: NSMaxRange(sel) - 1) == 10 {
            r = ns.lineRange(for: NSRange(location: sel.location, length: sel.length - 1))
        }
        return r
    }

    func transformLines(wholeIfEmpty: Bool = true, _ f: (String) throws -> String) {
        let r = targetLineRange(wholeIfEmpty: wholeIfEmpty)
        apply(f, to: r)
    }

    func transformSelection(_ f: (String) throws -> String) {
        let sel = selectedRange()
        apply(f, to: sel.length > 0 ? sel : NSRange(location: 0, length: ns.length))
    }

    private func apply(_ f: (String) throws -> String, to r: NSRange) {
        let old = ns.substring(with: r)
        do {
            let new = try f(old)
            if new != old { replace(r, with: new) }
        } catch {
            NSSound.beep()
            if let w = window { NSAlert(error: error).beginSheetModal(for: w) }
        }
    }

    // MARK: Line commands

    @objc func shiftRight(_ sender: Any?) { let u = indentUnit; transformLines(wholeIfEmpty: false) { TextTransforms.shiftRight($0, unit: u) } }
    @objc func shiftLeft(_ sender: Any?) { let w = tabWidth; transformLines(wholeIfEmpty: false) { TextTransforms.shiftLeft($0, tabWidth: w) } }

    @objc func toggleComment(_ sender: Any?) {
        if let p = language.lineComment {
            transformLines(wholeIfEmpty: false) { TextTransforms.toggleLineComment($0, prefix: p) }
        } else if let (o, c) = language.blockComment {
            if selectedRange().length == 0 { setSelectedRange(targetLineRange(wholeIfEmpty: false)) }
            transformSelection { s in
                let trailing = s.hasSuffix("\n")
                let body = trailing ? String(s.dropLast()) : s
                return TextTransforms.toggleBlockComment(body, open: o, close: c) + (trailing ? "\n" : "")
            }
        } else {
            NSSound.beep()
        }
    }

    @objc func duplicateLine(_ sender: Any?) {
        let r = targetLineRange(wholeIfEmpty: false)
        let text = ns.substring(with: r)
        let sel = selectedRange()
        let insertion = text.hasSuffix("\n") ? text : "\n" + text
        replace(NSRange(location: NSMaxRange(r), length: 0), with: insertion, select: false)
        // Caret moves to the copy, keeping its column.
        setSelectedRange(NSRange(location: sel.location + (insertion as NSString).length, length: sel.length))
    }

    @objc func deleteLine(_ sender: Any?) {
        let r = targetLineRange(wholeIfEmpty: false)
        var del = r
        // Last line without trailing newline: remove the preceding newline instead.
        if NSMaxRange(r) == ns.length, r.location > 0, !(ns.substring(with: r).hasSuffix("\n")) {
            del = NSRange(location: r.location - 1, length: r.length + 1)
        }
        replace(del, with: "", select: false)
        setSelectedRange(NSRange(location: min(del.location, ns.length), length: 0))
    }

    @objc func moveLineUp(_ sender: Any?) {
        let sel = selectedRange()
        let r = targetLineRange(wholeIfEmpty: false)
        guard r.location > 0 else { NSSound.beep(); return }
        let prev = ns.lineRange(for: NSRange(location: r.location - 1, length: 0))
        var a = ns.substring(with: r), b = ns.substring(with: prev)
        if !a.hasSuffix("\n") { a += "\n"; b.removeLast() }
        replace(NSUnionRange(prev, r), with: a + b, select: false)
        setSelectedRange(NSRange(location: prev.location + sel.location - r.location, length: sel.length))
    }

    @objc func moveLineDown(_ sender: Any?) {
        let sel = selectedRange()
        let r = targetLineRange(wholeIfEmpty: false)
        guard NSMaxRange(r) < ns.length else { NSSound.beep(); return }
        let next = ns.lineRange(for: NSRange(location: NSMaxRange(r), length: 0))
        var a = ns.substring(with: r), b = ns.substring(with: next)
        if !b.hasSuffix("\n") { b += "\n"; a.removeLast() }
        replace(NSUnionRange(r, next), with: b + a, select: false)
        setSelectedRange(NSRange(location: r.location + (b as NSString).length + sel.location - r.location, length: sel.length))
    }

    /// Selects the contents of the enclosing bracket pair; repeat to widen.
    @objc func balance(_ sender: Any?) {
        let pairs: [unichar: unichar] = [40: 41, 91: 93, 123: 125]   // ( ) [ ] { }
        let closers = Set(pairs.values)
        let sel = selectedRange()

        func matchForward(from start: Int, open: unichar) -> Int? {
            var depth = 0
            var i = start
            while i < ns.length {
                let c = ns.character(at: i)
                if c == open { depth += 1 }
                else if c == pairs[open] { if depth == 0 { return i }; depth -= 1 }
                i += 1
            }
            return nil
        }

        var stack: [unichar] = []
        var i = sel.location - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if closers.contains(c) {
                stack.append(c)
            } else if let close = pairs[c] {
                if let last = stack.last {
                    if last == close { stack.removeLast() }
                } else if let j = matchForward(from: i + 1, open: c), j >= NSMaxRange(sel) {
                    let inner = NSRange(location: i + 1, length: j - i - 1)
                    if inner == sel {
                        setSelectedRange(NSRange(location: i, length: j - i + 1))
                    } else {
                        setSelectedRange(inner)
                    }
                    scrollRangeToVisible(selectedRange())
                    return
                }
            }
            i -= 1
        }
        NSSound.beep()
    }

    // MARK: Text menu transforms

    @objc func makeUpperCase(_ sender: Any?) { transformSelection(TextTransforms.upperCase) }
    @objc func makeLowerCase(_ sender: Any?) { transformSelection(TextTransforms.lowerCase) }
    @objc func makeTitleCase(_ sender: Any?) { transformSelection(TextTransforms.titleCase) }
    @objc func capitalizeWordsCmd(_ sender: Any?) { transformSelection(TextTransforms.capitalizeWords) }
    @objc func capitalizeLinesCmd(_ sender: Any?) { transformSelection(TextTransforms.capitalizeLines) }
    @objc func capitalizeSentencesCmd(_ sender: Any?) { transformSelection(TextTransforms.capitalizeSentences) }

    @objc func sortLinesAscending(_ sender: Any?) { transformLines { TextTransforms.sortLines($0) } }
    @objc func sortLinesDescending(_ sender: Any?) { transformLines { TextTransforms.sortLines($0, .init(descending: true)) } }
    @objc func sortLinesNumeric(_ sender: Any?) { transformLines { TextTransforms.sortLines($0, .init(numeric: true)) } }
    @objc func sortLinesCaseSensitive(_ sender: Any?) { transformLines { TextTransforms.sortLines($0, .init(caseInsensitive: false)) } }
    @objc func removeDuplicateLines(_ sender: Any?) { transformLines(TextTransforms.removeDuplicateLines) }
    @objc func reverseLines(_ sender: Any?) { transformLines(TextTransforms.reverseLines) }
    @objc func addLineNumbers(_ sender: Any?) { transformLines { TextTransforms.addLineNumbers($0) } }
    @objc func removeLineNumbers(_ sender: Any?) { transformLines(TextTransforms.removeLineNumbers) }
    @objc func stripTrailingWhitespace(_ sender: Any?) { transformLines(TextTransforms.stripTrailingWhitespace) }
    @objc func zapGremlins(_ sender: Any?) { transformSelection(TextTransforms.zapGremlins) }
    @objc func removeLineBreaks(_ sender: Any?) { transformLines(TextTransforms.removeLineBreaks) }
    @objc func entab(_ sender: Any?) { let w = tabWidth; transformLines { TextTransforms.entab($0, tabWidth: w) } }
    @objc func detab(_ sender: Any?) { let w = tabWidth; transformLines { TextTransforms.detab($0, tabWidth: w) } }
    @objc func straightenQuotes(_ sender: Any?) { transformSelection(TextTransforms.straightenQuotes) }
    @objc func educateQuotes(_ sender: Any?) { transformSelection(TextTransforms.educateQuotes) }
    @objc func formatJSON(_ sender: Any?) { let w = tabWidth; transformSelection { try TextTransforms.formatJSON($0, indent: w) } }

    @objc func hardWrap(_ sender: Any?) {
        guard let s = prompt("Hard Wrap", message: "Wrap lines at column:", defaultValue: "\(pageGuideColumn)"), let w = Int(s), w > 0 else { return }
        transformLines { TextTransforms.hardWrap($0, width: w) }
    }

    @objc func prefixSuffixLines(_ sender: Any?) {
        guard let p = prompt("Prefix Lines", message: "Text to add before each line (may be empty):", defaultValue: "") else { return }
        guard let s = prompt("Suffix Lines", message: "Text to add after each line (may be empty):", defaultValue: "") else { return }
        transformLines { TextTransforms.prefixSuffix($0, prefix: p, suffix: s) }
    }

    @objc func processLinesContaining(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Process Lines Containing"
        alert.informativeText = "Keep or delete the lines that match a pattern (grep syntax)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Pattern"
        alert.accessoryView = field
        alert.addButton(withTitle: "Keep Matching")
        alert.addButton(withTitle: "Delete Matching")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn, !field.stringValue.isEmpty else { return }
        do {
            let regex = try NSRegularExpression(pattern: field.stringValue)
            let keep = response == .alertFirstButtonReturn
            transformLines { TextTransforms.processLines($0, matching: regex, keep: keep) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func showStatistics(_ sender: Any?) {
        let sel = selectedRange()
        let target = sel.length > 0 ? ns.substring(with: sel) : string
        let st = TextTransforms.statistics(target)
        let alert = NSAlert()
        alert.messageText = sel.length > 0 ? "Selection Statistics" : "Document Statistics"
        let f = NumberFormatter(); f.numberStyle = .decimal
        func n(_ v: Int) -> String { f.string(from: v as NSNumber) ?? "\(v)" }
        alert.informativeText = "Characters: \(n(st.characters))\nWords: \(n(st.words))\nLines: \(n(st.lines))\nUTF-8 bytes: \(n(target.utf8.count))"
        if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    // MARK: Navigation

    @objc func goToLine(_ sender: Any?) {
        guard let s = prompt("Go to Line", message: "Line number (or line:column):", defaultValue: ""),
              !s.isEmpty else { return }
        let parts = s.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let line = parts.first else { NSSound.beep(); return }
        selectLine(line, column: parts.count > 1 ? max(0, parts[1] - 1) : 0, length: 0, selectWholeLine: parts.count == 1)
    }

    func selectLine(_ line: Int, column: Int, length: Int, selectWholeLine: Bool = false) {
        let index = LineIndex(string)
        let lr = index.range(ofLine: line - 1)
        let r = selectWholeLine ? lr : NSRange(location: min(lr.location + column, ns.length), length: min(length, max(0, ns.length - lr.location - column)))
        setSelectedRange(r)
        scrollRangeToVisible(r)
        if r.length > 0 { showFindIndicator(for: r) }
        window?.makeFirstResponder(self)
    }

    func prompt(_ title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// The Font panel sets the editor-wide font rather than styling a range.
    override func changeFont(_ sender: Any?) {
        guard let fm = sender as? NSFontManager else { return }
        Prefs.setFont(fm.convert(font ?? Prefs.font))
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleComment(_:)): return language.lineComment != nil || language.blockComment != nil
        default: return super.validateMenuItem(item)
        }
    }
}
