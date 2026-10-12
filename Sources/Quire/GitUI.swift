import AppKit
import QuireCore

/// Git menu commands. They act on the front document's repository.
extension AppDelegate {

    private func gitContext() -> (EditorViewController, GitRepository, URL)? {
        guard let ed = NSApp.mainEditor, let url = ed.doc?.fileURL, ed.doc?.remote == nil else {
            alert("No local file", "Save the document inside a Git working copy first.")
            return nil
        }
        guard let repo = ed.repository ?? GitRepository.containing(url) else {
            alert("Not in a Git repository", "“\(url.lastPathComponent)” isn’t inside a Git working copy.")
            return nil
        }
        return (ed, repo, url)
    }

    func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        if let w = NSApp.mainWindow { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    /// Runs `work` off the main thread and reports failures.
    private func gitRun<T>(_ label: String, _ work: @escaping () throws -> T, then: @escaping (T) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try work() }
            DispatchQueue.main.async {
                switch r {
                case .success(let v): then(v)
                case .failure(let e): self.alert("\(label) failed", e.localizedDescription)
                }
            }
        }
    }

    /// Refreshes markers in every open editor belonging to `repo`.
    func refreshGitEditors(_ repo: GitRepository) {
        for case let d as Document in NSDocumentController.shared.documents {
            if let url = d.fileURL, url.path.hasPrefix(repo.root.path) { d.editor.refreshGit(reloadHead: true) }
        }
    }

    @objc func gitShowChanges(_ sender: Any?) {
        guard let (ed, repo, url) = gitContext() else { return }
        let rel = repo.relativePath(url)
        let text = ed.textView.string
        gitRun("Compare with HEAD", { repo.headContents(of: url) }) { head in
            DiffWindowController.show(oldText: head ?? "", newText: text, oldName: "HEAD:\(rel)", newName: "\(rel) (working copy)")
        }
    }

    @objc func gitRepositoryDiff(_ sender: Any?) {
        guard let (_, repo, _) = gitContext() else { return }
        gitRun("Diff", { (try repo.diff(nil, staged: true), try repo.diff(nil)) }) { staged, unstaged in
            let text = (staged.isEmpty ? "" : "# Staged changes\n" + staged + "\n") + (unstaged.isEmpty ? "" : "# Unstaged changes\n" + unstaged)
            if text.isEmpty { self.alert("No changes", "The working copy matches HEAD."); return }
            TextOutputWindowController.show(title: "Diff — \(repo.root.lastPathComponent)", text: text, diff: true)
        }
    }

    @objc func gitBlame(_ sender: Any?) {
        guard let (ed, repo, url) = gitContext() else { return }
        if ed.doc?.isDocumentEdited == true {
            alert("Unsaved changes", "Blame shows the saved file; your unsaved edits won’t appear.")
        }
        gitRun("Blame", { try repo.blame(url) }) { lines in
            BlameWindowController.show(file: url, lines: lines)
        }
    }

    @objc func gitFileLog(_ sender: Any?) {
        guard let (_, repo, url) = gitContext() else { return }
        gitRun("Log", { try repo.log(url) }) { log in
            TextOutputWindowController.show(title: "History — \(url.lastPathComponent)", text: log.isEmpty ? "No commits yet." : log, diff: false)
        }
    }

    @objc func gitRepositoryStatus(_ sender: Any?) {
        guard let (_, repo, _) = gitContext() else { return }
        gitRun("Status", { try repo.status() }) { entries in
            let branch = repo.currentBranch() ?? "?"
            if entries.isEmpty { self.alert("Working copy clean", "Nothing to commit on \(branch)."); return }
            let hits = entries.map { e in
                SearchHit(url: repo.root.appendingPathComponent(e.path), line: 1, column: 0, length: 0, lineText: "\(e.code)  \(e.summary)")
            }
            SearchResultsWindowController.show(title: "Git status (\(branch))", hits: hits, document: nil, showFiles: true, root: repo.root)
        }
    }

    @objc func gitStageFile(_ sender: Any?) {
        guard let (ed, repo, url) = gitContext() else { return }
        if ed.doc?.isDocumentEdited == true { ed.doc?.save(nil) }
        gitRun("Stage", { try repo.stage(url) }) { _ in self.refreshGitEditors(repo) }
    }

    @objc func gitUnstageFile(_ sender: Any?) {
        guard let (_, repo, url) = gitContext() else { return }
        gitRun("Unstage", { try repo.unstage(url) }) { _ in self.refreshGitEditors(repo) }
    }

    @objc func gitDiscardChanges(_ sender: Any?) {
        guard let (ed, repo, url) = gitContext() else { return }
        let a = NSAlert()
        a.messageText = "Discard changes to “\(url.lastPathComponent)”?"
        a.informativeText = "The file will be restored to the version in HEAD. Unsaved edits and uncommitted changes are lost."
        a.addButton(withTitle: "Discard Changes")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        gitRun("Discard changes", { try repo.discardChanges(url) }) { _ in
            if let doc = ed.doc { try? doc.revert(toContentsOf: url, ofType: doc.fileType ?? "public.plain-text") }
            self.refreshGitEditors(repo)
        }
    }

    @objc func gitCommit(_ sender: Any?) {
        guard let (_, repo, _) = gitContext() else { return }
        // Save edited documents in this repository first.
        for case let d as Document in NSDocumentController.shared.documents where d.isDocumentEdited {
            if let u = d.fileURL, u.path.hasPrefix(repo.root.path) { d.save(nil) }
        }
        let a = NSAlert()
        a.messageText = "Commit to \(repo.currentBranch() ?? repo.root.lastPathComponent)"
        a.informativeText = "Enter a commit message."
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 30, width: 420, height: 120)
        scroll.borderType = .bezelBorder
        let tv = scroll.documentView as! NSTextView
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isRichText = false
        let all = NSButton(checkboxWithTitle: "Include all modified tracked files (git commit -a)", target: nil, action: nil)
        all.frame = NSRect(x: 0, y: 0, width: 420, height: 22)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        box.addSubview(scroll); box.addSubview(all)
        a.accessoryView = box
        a.addButton(withTitle: "Commit")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tv
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let message = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { alert("Commit cancelled", "The commit message was empty."); return }
        let includeAll = all.state == .on
        gitRun("Commit", { try repo.commit(message: message, all: includeAll) }) { out in
            self.refreshGitEditors(repo)
            self.alert("Committed", out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Shows `git blame` as a table: commit, author, date, line, text.
final class BlameWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static var open: [BlameWindowController] = []
    private let lines: [BlameLine]
    private let file: URL
    private let table = NSTableView()
    private let dateFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; return f }()

    static func show(file: URL, lines: [BlameLine]) {
        let wc = BlameWindowController(file: file, lines: lines)
        open.append(wc)
        wc.showWindow(nil)
    }

    private init(file: URL, lines: [BlameLine]) {
        self.file = file; self.lines = lines
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Blame — \(file.lastPathComponent)"
        super.init(window: w)
        w.delegate = self
        w.center()
        for (id, title, width) in [("commit", "Commit", 80.0), ("author", "Author", 130.0), ("date", "Date", 80.0), ("line", "Line", 50.0), ("text", "Text", 560.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(openLine(_:))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = table
        w.contentView = scroll
    }

    required init?(coder: NSCoder) { fatalError() }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let l = lines[row]
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byTruncatingTail
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        // Only label the first line of each run from the same commit.
        let repeatRun = row > 0 && lines[row - 1].commit == l.commit
        switch id {
        case "commit": f.stringValue = repeatRun ? "" : l.commit; f.font = mono; f.textColor = .secondaryLabelColor
        case "author": f.stringValue = repeatRun ? "" : l.author; f.toolTip = l.summary
        case "date": f.stringValue = repeatRun ? "" : dateFormatter.string(from: l.date); f.textColor = .secondaryLabelColor
        case "line": f.stringValue = "\(row + 1)"; f.font = mono; f.alignment = .right; f.textColor = .secondaryLabelColor
        default: f.stringValue = l.text.replacingOccurrences(of: "\t", with: "    "); f.font = mono
        }
        return f
    }

    @objc private func openLine(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        (NSDocumentController.shared as? DocumentController)?.open(file, line: table.clickedRow + 1)
    }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }
}
