import AppKit
import QuireCore

/// Lists search hits; double-click (or Return) opens the file at the match.
final class SearchResultsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static var open: [SearchResultsWindowController] = []

    let hits: [SearchHit]
    weak var sourceDocument: Document?
    let showFiles: Bool
    let root: URL?
    private let table = NSTableView()

    static func show(title: String, hits: [SearchHit], document: Document?, showFiles: Bool, root: URL? = nil) {
        let wc = SearchResultsWindowController(title: title, hits: hits, document: document, showFiles: showFiles, root: root)
        open.append(wc)
        wc.showWindow(nil)
    }

    private init(title: String, hits: [SearchHit], document: Document?, showFiles: Bool, root: URL?) {
        self.hits = hits; self.sourceDocument = document; self.showFiles = showFiles; self.root = root
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "\(title) — \(hits.count) result\(hits.count == 1 ? "" : "s")"
        super.init(window: w)
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("QuireSearchResults")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        w.contentView = scroll

        func col(_ id: String, _ title: String, _ width: CGFloat) {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = width
            table.addTableColumn(c)
        }
        if showFiles { col("file", "File", 220) }
        col("line", "Line", 56)
        col("text", "Text", 520)
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.allowsMultipleSelection = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = NSUserInterfaceItemIdentifier(id)
            f.lineBreakMode = id == "file" ? .byTruncatingHead : .byTruncatingTail
            return f
        }()
        let hit = hits[row]
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        switch id {
        case "file":
            if let url = hit.url, let root, url.path.hasPrefix(root.path + "/") {
                cell.stringValue = String(url.path.dropFirst(root.path.count + 1))
            } else {
                cell.stringValue = hit.url?.lastPathComponent ?? "untitled"
            }
            cell.font = NSFont.systemFont(ofSize: 12)
            cell.textColor = .secondaryLabelColor
        case "line":
            cell.stringValue = "\(hit.line)"
            cell.font = mono
            cell.alignment = .right
            cell.textColor = .secondaryLabelColor
        default:
            let trimmed = hit.lineText.prefix { $0 == " " || $0 == "\t" }.count
            let s = NSMutableAttributedString(string: String(hit.lineText.dropFirst(trimmed)).replacingOccurrences(of: "\t", with: " "),
                                              attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
            let start = hit.column - (hit.lineText.prefix(trimmed).utf16.count)
            let r = NSRange(location: max(0, start), length: hit.length)
            if NSMaxRange(r) <= s.length {
                s.addAttributes([.backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.55),
                                 .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)], range: r)
            }
            cell.attributedStringValue = s
        }
        return cell
    }

    @objc private func openSelected(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 else { return }
        let hit = hits[row]
        if let doc = sourceDocument ?? hit.url.flatMap({ url in NSDocumentController.shared.documents.first { $0.fileURL == url } as? Document }) {
            doc.editor.select(line: hit.line, column: hit.column, length: hit.length)
        } else if let url = hit.url {
            (NSDocumentController.shared as? DocumentController)?.open(url, line: hit.line, column: hit.column, length: hit.length)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openSelected(nil) } else { super.keyDown(with: event) }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

/// Shows text output (git log, command output) or a unified diff with
/// coloured additions and deletions.
final class TextOutputWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [TextOutputWindowController] = []

    static func show(title: String, text: String, diff: Bool) {
        let wc = TextOutputWindowController(text: text, title: title, diff: diff)
        open.append(wc)
        wc.showWindow(nil)
    }

    private init(text: String, title: String, diff: Bool) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        super.init(window: w)
        w.delegate = self
        w.center()

        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        let add = NSColor.systemGreen.withAlphaComponent(0.16), del = NSColor.systemRed.withAlphaComponent(0.16)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var attrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.labelColor]
            if diff {
                if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") || line.hasPrefix("# ") {
                    attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
                } else if line.hasPrefix("@@") {
                    attrs[.foregroundColor] = NSColor.systemBlue
                } else if line.hasPrefix("+") {
                    attrs[.backgroundColor] = add
                } else if line.hasPrefix("-") {
                    attrs[.backgroundColor] = del
                } else if line.hasPrefix("index ") {
                    attrs[.foregroundColor] = NSColor.secondaryLabelColor
                }
            }
            out.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        tv.textStorage?.setAttributedString(out)
        w.contentView = scroll
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }
}

enum DiffWindowController {
    static func show(oldText: String, newText: String, oldName: String, newName: String) {
        let diff = LineDiff.unified(old: oldText, new: newText, oldName: oldName, newName: newName)
        if diff.isEmpty {
            let a = NSAlert()
            a.messageText = "No differences"
            a.informativeText = "“\(oldName)” and “\(newName)” are identical."
            a.runModal()
            return
        }
        TextOutputWindowController.show(title: "Differences: \(oldName) ↔ \(newName)", text: diff, diff: true)
    }
}
