import AppKit
import UniformTypeIdentifiers
import QuireCore

/// Markdown editing in the text view: list and quote continuation, list indenting,
/// the Format menu, wrapping a selection by typing a marker, and smart paste and drop
/// of links and images. Active only when the document's language is Markdown.
extension EditorTextView {

    var isMarkdown: Bool { language.name == "Markdown" }

    func apply(_ edit: MarkdownEditing.Edit) {
        replace(edit.range, with: edit.replacement, select: false)
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    /// Return in a list item, quote or at the end of a table row. True when handled.
    func markdownNewline() -> Bool {
        let sel = selectedRange()
        guard isMarkdown, sel.length == 0 else { return false }
        if let edit = MarkdownEditing.tableNewline(string, cursor: sel.location) { apply(edit); return true }
        guard let edit = MarkdownEditing.newline(in: string, cursor: sel.location) else { return false }
        apply(edit)
        if let renumber = MarkdownEditing.renumber(string, around: selectedRange().location) { apply(renumber) }
        return true
    }

    /// Tab and Shift-Tab in a table: format it and move between cells. True when handled.
    func markdownTableTab(backward: Bool) -> Bool {
        let sel = selectedRange()
        guard isMarkdown, !(string as NSString).substring(with: sel).contains("\n"),
              let edit = MarkdownEditing.tableTab(string, cursor: sel.location, backward: backward) else { return false }
        apply(edit)
        return true
    }

    /// Tab and Shift-Tab on a single list item line move it in or out a level. True when handled.
    func markdownIndentListItem(outdent: Bool) -> Bool {
        let sel = selectedRange()
        let ns = string as NSString
        guard isMarkdown, !ns.substring(with: sel).contains("\n"), MarkdownEditing.isListItem(string, at: sel.location) else { return false }
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.length
        if outdent { shiftLeft(nil) } else { shiftRight(nil) }
        let moved = (string as NSString).length - before
        setSelectedRange(NSRange(location: max(line.location, sel.location + moved), length: sel.length))
        // An item moved into a new nested list starts it at 1; then both lists are renumbered.
        if !outdent { restartNestedNumbering() }
        let cursor = selectedRange().location
        let current = (string as NSString).lineRange(for: NSRange(location: cursor, length: 0))
        for probe in [cursor, max(0, current.location - 1), NSMaxRange(current)] where probe <= (string as NSString).length {
            if let renumber = MarkdownEditing.renumber(string, around: probe) {
                let keep = selectedRange()
                replace(renumber.range, with: renumber.replacement, select: false)
                let shift = renumber.range.location < keep.location ? (renumber.replacement as NSString).length - renumber.range.length : 0
                setSelectedRange(NSRange(location: keep.location + shift, length: keep.length))
            }
        }
        return true
    }

    /// After Tab on an ordered item: unless the line above is an ordered item at the same
    /// indent (so the item joins that list), the item becomes number 1 of a new nested list.
    private func restartNestedNumbering() {
        let ns = string as NSString
        let keep = selectedRange()
        let line = ns.lineRange(for: NSRange(location: keep.location, length: 0))
        let text = ns.substring(with: line)
        let ordered = #"^([ \t]*)(\d+)[.)]"#
        guard let m = try? NSRegularExpression(pattern: ordered).firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return }
        let indent = (text as NSString).substring(with: m.range(at: 1))
        if line.location > 0 {
            let above = ns.substring(with: ns.lineRange(for: NSRange(location: line.location - 1, length: 0)))
            if let a = try? NSRegularExpression(pattern: ordered).firstMatch(in: above, range: NSRange(location: 0, length: (above as NSString).length)),
               (above as NSString).substring(with: a.range(at: 1)) == indent { return }
        }
        let digits = m.range(at: 2)
        guard (text as NSString).substring(with: digits) != "1" else { return }
        replace(NSRange(location: line.location + digits.location, length: digits.length), with: "1", select: false)
        setSelectedRange(NSRange(location: keep.location - digits.length + 1, length: keep.length))
    }

    /// Typing `*`, `_`, `` ` `` or `~` with a single-line selection wraps it. True when handled.
    func markdownWrapSelection(typing s: String) -> Bool {
        let sel = selectedRange()
        guard isMarkdown, ["*", "_", "`", "~"].contains(s), sel.length > 0,
              !(string as NSString).substring(with: sel).contains("\n") else { return false }
        let inner = (string as NSString).substring(with: sel)
        replace(sel, with: s + inner + s, select: false)
        setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
        return true
    }

    // MARK: Format menu

    private func wrap(_ marker: String) {
        guard isMarkdown else { NSSound.beep(); return }
        apply(MarkdownEditing.toggleWrap(string, selection: selectedRange(), marker: marker))
    }

    @objc func toggleBold(_ sender: Any?) { wrap("**") }
    @objc func toggleItalic(_ sender: Any?) { wrap("*") }
    @objc func toggleInlineCode(_ sender: Any?) { wrap("`") }
    @objc func toggleStrikethrough(_ sender: Any?) { wrap("~~") }

    /// Wraps the selection in a link, using a URL on the clipboard when there is one.
    @objc func insertMarkdownLink(_ sender: Any?) {
        guard isMarkdown else { NSSound.beep(); return }
        let clip = NSPasteboard.general.string(forType: .string)
        let url = clip.flatMap { MarkdownEditing.isLinkable($0) ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        apply(MarkdownEditing.link(string, selection: selectedRange(), url: url))
    }

    /// Heading level from the menu item's tag (1–6).
    @objc func setHeadingLevel(_ sender: Any?) {
        guard isMarkdown, let level = (sender as? NSMenuItem)?.tag, (1...6).contains(level) else { NSSound.beep(); return }
        apply(MarkdownEditing.heading(string, cursor: selectedRange().location, level: level))
    }

    @objc func renumberList(_ sender: Any?) {
        guard isMarkdown, let edit = MarkdownEditing.renumber(string, around: selectedRange().location) else { NSSound.beep(); return }
        apply(edit)
    }

    /// ⌘B and ⌘I format Markdown even though Balance owns ⌘B elsewhere.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isMarkdown, window?.firstResponder === self, let key = event.charactersIgnoringModifiers?.lowercased() {
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if mods == .command && key == "b" { toggleBold(nil); return true }
            if mods == .command && key == "i" { toggleItalic(nil); return true }
            if mods == [.command, .control] && key == "b" { balance(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Clicks in Live Preview

    /// Clicking a checkbox toggles the task; ⌘-click opens a link. True when handled.
    func handleMarkdownClick(_ event: NSEvent) -> Bool {
        guard isMarkdown, let lm = layoutManager as? InvisiblesLayoutManager, let fm = foldManager else { return false }
        var p = convert(event.locationInWindow, from: nil)
        p.x -= textContainerOrigin.x
        p.y -= textContainerOrigin.y
        for m in fm.markup {
            guard case .checkbox(let checked) = m.style, lm.checkboxRect(for: m).insetBy(dx: -3, dy: -3).contains(p) else { continue }
            toggleTask(at: m.range.location, checked: checked)
            return true
        }
        if event.modifierFlags.contains(.command), let resolve = linkResolver {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if let url = resolve(index) ?? (index > 0 ? resolve(index - 1) : nil) {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        return false
    }

    /// Flips `[ ]` and `[x]` for the task marker starting at `location`.
    func toggleTask(at location: Int, checked: Bool) {
        let mark = NSRange(location: location + 1, length: 1)
        guard NSMaxRange(mark) <= (string as NSString).length else { return }
        let keep = selectedRange()
        replace(mark, with: checked ? " " : "x", select: false)
        setSelectedRange(keep)
    }

    // MARK: Paste and drop

    /// Where pasted and dropped images go: the images folder setting, relative to the document.
    var markdownAssetsFolder: URL? {
        guard let dir = (window?.windowController?.document as? Document ?? NSApp.activeEditor?.doc)?.fileURL?.deletingLastPathComponent() else { return nil }
        let name = Prefs.markdownImagesFolder
        return name.isEmpty ? dir : dir.appendingPathComponent(name, isDirectory: true)
    }

    /// The document's own folder (image links are relative to it).
    var markdownDocumentFolder: URL? {
        (window?.windowController?.document as? Document ?? NSApp.activeEditor?.doc)?.fileURL?.deletingLastPathComponent()
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if isMarkdown, let handled = readMarkdown(from: pboard) { return handled }
        return super.readSelection(from: pboard, type: type)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        isMarkdown ? [.fileURL, .png, .tiff] + super.readablePasteboardTypes : super.readablePasteboardTypes
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tif", "tiff", "bmp", "avif"]

    /// Image files become image links; image data is saved into `assets/`; a URL pasted over
    /// a selection becomes a link. Nil leaves the paste to the text view.
    private func readMarkdown(from pboard: NSPasteboard) -> Bool? {
        let sel = selectedRange()
        let files = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let images = files.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
        if !images.isEmpty, images.count == files.count {
            guard let assets = markdownAssetsFolder, let docDir = markdownDocumentFolder else { return askToSaveFirst() }
            var links: [String] = []
            for file in images {
                var target = file
                // Images outside the document's folder are copied into assets/.
                if !file.standardizedFileURL.path.hasPrefix(docDir.standardizedFileURL.path + "/") {
                    target = uniqueFile(in: assets, name: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension)
                    do {
                        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: file, to: target)
                    } catch { NSSound.beep(); return true }
                }
                let alt = file.deletingPathExtension().lastPathComponent
                links.append("![\(alt)](\(MarkdownEditing.relativePath(of: target, from: docDir)))")
            }
            insertText(links.joined(separator: "\n"), replacementRange: sel)
            return true
        }
        if files.isEmpty, let data = pboard.data(forType: .png) ?? pboard.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }),
           pboard.string(forType: .string) == nil {
            guard let assets = markdownAssetsFolder else { return askToSaveFirst() }
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
                .replacingOccurrences(of: ":", with: "")
            let file = uniqueFile(in: assets, name: "image-\(stamp)", ext: "png")
            do {
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                try data.write(to: file)
            } catch { NSSound.beep(); return true }
            insertText("![](\(MarkdownEditing.relativePath(of: file, from: markdownDocumentFolder ?? assets)))", replacementRange: sel)
            return true
        }
        if sel.length > 0, let s = pboard.string(forType: .string), MarkdownEditing.isLinkable(s),
           !(string as NSString).substring(with: sel).contains("\n") {
            apply(MarkdownEditing.link(string, selection: sel, url: s.trimmingCharacters(in: .whitespacesAndNewlines)))
            return true
        }
        return nil
    }

    private func uniqueFile(in dir: URL, name: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    private func askToSaveFirst() -> Bool {
        guard let window else { NSSound.beep(); return true }
        let alert = NSAlert()
        alert.messageText = "Save the document first"
        alert.informativeText = "Pasted and dropped images are saved in a folder next to the document (View ▸ Markdown ▸ Folder for Pasted Images)."
        alert.beginSheetModal(for: window)
        return true
    }
}
