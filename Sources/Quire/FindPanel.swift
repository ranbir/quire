import AppKit
import QuireCore

/// Find & Replace window with grep (regex) support and multi-file search.
final class FindPanelController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = FindPanelController()

    let findField = NSTextField()
    let replaceField = NSTextField()
    let caseBox = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    let wordBox = NSButton(checkboxWithTitle: "Entire word", target: nil, action: nil)
    let grepBox = NSButton(checkboxWithTitle: "Grep", target: nil, action: nil)
    let wrapBox = NSButton(checkboxWithTitle: "Wrap around", target: nil, action: nil)
    let selectionBox = NSButton(checkboxWithTitle: "Selection only", target: nil, action: nil)
    let folderField = NSTextField()
    let filterField = NSTextField()
    let hiddenBox = NSButton(checkboxWithTitle: "Include hidden files", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var searchButton: NSButton!
    private var searchCancelled = false
    private var searching = false

    private let defaults = UserDefaults.standard

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = "Find"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.setFrameAutosaveName("QuireFindPanel")
        super.init(window: panel)
        panel.delegate = self
        build()
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func button(_ title: String, _ action: Selector, key: String = "") -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.keyEquivalent = key
        return b
    }

    private func build() {
        guard let content = window?.contentView else { return }
        for f in [findField, replaceField, folderField, filterField] {
            f.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            f.lineBreakMode = .byTruncatingTail
            f.usesSingleLineMode = true
            f.delegate = self
        }
        findField.placeholderString = "Search for"
        replaceField.placeholderString = "Replace with  (grep: \\1 for groups, & for match)"
        folderField.placeholderString = "Folder for multi-file search"
        filterField.placeholderString = "File filter, e.g. *.swift, *.m  (empty = all text files)"
        for b in [caseBox, wordBox, grepBox, wrapBox, selectionBox, hiddenBox] {
            b.target = self; b.action = #selector(optionChanged(_:))
        }

        let options = NSStackView(views: [caseBox, wordBox, grepBox, wrapBox, selectionBox])
        options.spacing = 14

        let choose = button("Choose…", #selector(chooseFolder(_:)))
        let folderRow = NSStackView(views: [folderField, choose])
        folderRow.spacing = 6

        let grid = NSGridView(views: [
            [label("Find:"), findField],
            [label("Replace:"), replaceField],
            [NSGridCell.emptyContentView, options],
            [label("In folder:"), folderRow],
            [label("Files:"), filterField],
            [NSGridCell.emptyContentView, hiddenBox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.row(at: 3).topPadding = 10

        let buttons1 = NSStackView(views: [
            button("Previous", #selector(findPrevious(_:))),
            button("Next", #selector(findNext(_:)), key: "\r"),
            button("Find All", #selector(findAll(_:))),
        ])
        let buttons2 = NSStackView(views: [
            button("Replace", #selector(replace(_:))),
            button("Replace & Find", #selector(replaceAndFind(_:))),
            button("Replace All", #selector(replaceAll(_:))),
        ])
        searchButton = button("Search Folder", #selector(searchFolder(_:)))
        let buttons3 = NSStackView(views: [searchButton])
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSStackView(views: [spinner, statusLabel])

        let outer = NSStackView(views: [grid, buttons1, buttons2, buttons3, status])
        outer.orientation = .vertical
        outer.alignment = .trailing
        outer.spacing = 10
        outer.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 16),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            status.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 16),
        ])
        window?.initialFirstResponder = findField
    }

    // MARK: Persistence

    private func load() {
        findField.stringValue = defaults.string(forKey: "find.pattern") ?? ""
        replaceField.stringValue = defaults.string(forKey: "find.replace") ?? ""
        folderField.stringValue = defaults.string(forKey: "find.folder") ?? ""
        filterField.stringValue = defaults.string(forKey: "find.filter") ?? ""
        caseBox.state = defaults.bool(forKey: "find.case") ? .on : .off
        wordBox.state = defaults.bool(forKey: "find.word") ? .on : .off
        grepBox.state = defaults.bool(forKey: "find.grep") ? .on : .off
        wrapBox.state = (defaults.object(forKey: "find.wrap") as? Bool ?? true) ? .on : .off
        hiddenBox.state = defaults.bool(forKey: "find.hidden") ? .on : .off
    }

    private func save() {
        defaults.set(findField.stringValue, forKey: "find.pattern")
        defaults.set(replaceField.stringValue, forKey: "find.replace")
        defaults.set(folderField.stringValue, forKey: "find.folder")
        defaults.set(filterField.stringValue, forKey: "find.filter")
        defaults.set(caseBox.state == .on, forKey: "find.case")
        defaults.set(wordBox.state == .on, forKey: "find.word")
        defaults.set(grepBox.state == .on, forKey: "find.grep")
        defaults.set(wrapBox.state == .on, forKey: "find.wrap")
        defaults.set(hiddenBox.state == .on, forKey: "find.hidden")
    }

    @objc private func optionChanged(_ sender: Any?) { save() }
    func controlTextDidChange(_ obj: Notification) { save(); statusLabel.stringValue = "" }

    var options: SearchOptions {
        SearchOptions(pattern: findField.stringValue, caseSensitive: caseBox.state == .on,
                      wholeWord: wordBox.state == .on, grep: grepBox.state == .on, wrapAround: wrapBox.state == .on)
    }

    private var editor: EditorViewController? { NSApp.activeEditor }

    private func compiledRegex() -> NSRegularExpression? {
        guard !findField.stringValue.isEmpty else { NSSound.beep(); return nil }
        do { return try SearchEngine.regex(for: options) } catch {
            statusLabel.stringValue = "Invalid pattern: \(error.localizedDescription)"
            NSSound.beep()
            return nil
        }
    }

    func show(withSelectionFrom tv: NSTextView?) {
        if let tv, tv.selectedRange().length > 0, tv.selectedRange().length < 500 {
            let sel = (tv.string as NSString).substring(with: tv.selectedRange())
            if !sel.contains("\n") { findField.stringValue = grepBox.state == .on ? NSRegularExpression.escapedPattern(for: sel) : sel; save() }
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(findField)
        findField.selectText(nil)
    }

    func showMultiFile() {
        if folderField.stringValue.isEmpty, let url = editor?.doc?.fileURL?.deletingLastPathComponent() {
            folderField.stringValue = url.path
        }
        show(withSelectionFrom: editor?.textView)
    }

    func useSelectionForFind(_ tv: NSTextView) {
        let sel = (tv.string as NSString).substring(with: tv.selectedRange())
        guard !sel.isEmpty else { NSSound.beep(); return }
        findField.stringValue = grepBox.state == .on ? NSRegularExpression.escapedPattern(for: sel) : sel
        save()
    }

    func useSelectionForReplace(_ tv: NSTextView) {
        replaceField.stringValue = (tv.string as NSString).substring(with: tv.selectedRange())
        save()
    }

    // MARK: Single-document actions

    @discardableResult
    private func find(backwards: Bool) -> Bool {
        guard let ed = editor, let regex = compiledRegex() else { return false }
        let tv = ed.textView
        let opts = options
        if let r = SearchEngine.find(in: tv.string, regex: regex, from: tv.selectedRange(), backwards: backwards, wrap: opts.wrapAround) {
            tv.setSelectedRange(r)
            tv.scrollRangeToVisible(r)
            tv.showFindIndicator(for: r)
            statusLabel.stringValue = ""
            return true
        }
        statusLabel.stringValue = "Not found"
        NSSound.beep()
        return false
    }

    @objc func findNext(_ sender: Any?) { find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(backwards: true) }

    /// Replaces the current selection if it is a match. Returns true when replaced.
    @discardableResult
    @objc func replace(_ sender: Any?) -> Bool {
        guard let ed = editor, let regex = compiledRegex() else { return false }
        let tv = ed.textView
        let sel = tv.selectedRange()
        guard sel.length > 0, let m = regex.firstMatch(in: tv.string, options: [], range: sel), m.range == sel else {
            NSSound.beep(); return false
        }
        let template = SearchEngine.replacementTemplate(replaceField.stringValue, grep: grepBox.state == .on)
        let replacement = regex.replacementString(for: m, in: tv.string, offset: 0, template: template)
        tv.replace(sel, with: replacement, select: false)
        tv.setSelectedRange(NSRange(location: sel.location + (replacement as NSString).length, length: 0))
        return true
    }

    @objc func replaceAndFind(_ sender: Any?) {
        replace(sender)
        find(backwards: false)
    }

    @objc func replaceAll(_ sender: Any?) {
        guard let ed = editor, let regex = compiledRegex() else { return }
        let tv = ed.textView
        let text = tv.string
        let range = selectionBox.state == .on && tv.selectedRange().length > 0
            ? tv.selectedRange() : NSRange(location: 0, length: (text as NSString).length)
        let count = regex.numberOfMatches(in: text, range: range)
        guard count > 0 else { statusLabel.stringValue = "Not found"; NSSound.beep(); return }
        let template = SearchEngine.replacementTemplate(replaceField.stringValue, grep: grepBox.state == .on)
        let segment = (text as NSString).substring(with: range)
        let replaced = regex.stringByReplacingMatches(in: segment, range: NSRange(location: 0, length: (segment as NSString).length), withTemplate: template)
        tv.replace(range, with: replaced, select: selectionBox.state == .on)
        statusLabel.stringValue = "Replaced \(count) occurrence\(count == 1 ? "" : "s")"
    }

    @objc func findAll(_ sender: Any?) {
        guard let ed = editor, let regex = compiledRegex() else { return }
        let tv = ed.textView
        let range = selectionBox.state == .on && tv.selectedRange().length > 0 ? tv.selectedRange() : nil
        let hits = SearchEngine.findAll(in: tv.string, regex: regex, url: ed.doc?.fileURL, range: range)
        statusLabel.stringValue = "\(hits.count) match\(hits.count == 1 ? "" : "es")"
        guard !hits.isEmpty else { NSSound.beep(); return }
        SearchResultsWindowController.show(title: "“\(findField.stringValue)” in \(ed.displayName)",
                                           hits: hits, document: ed.doc, showFiles: false)
    }

    // MARK: Multi-file search

    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if !folderField.stringValue.isEmpty { panel.directoryURL = URL(fileURLWithPath: folderField.stringValue) }
        guard let w = window else { return }
        panel.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let url = panel.url { self?.folderField.stringValue = url.path; self?.save() }
        }
    }

    @objc func searchFolder(_ sender: Any?) {
        if searching { searchCancelled = true; return }
        guard let regexCheck = compiledRegex(), regexCheck.pattern.count > 0 else { return }
        let path = (folderField.stringValue as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            statusLabel.stringValue = "Choose a folder to search"
            NSSound.beep()
            return
        }
        let folder = URL(fileURLWithPath: path)
        let opts = options, filter = filterField.stringValue, hidden = hiddenBox.state == .on
        searching = true; searchCancelled = false
        spinner.startAnimation(nil)
        searchButton.title = "Stop"
        var scanned = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try SearchEngine.searchFolder(folder, options: opts, fileFilter: filter, includeHidden: hidden) { url in
                    scanned += 1
                    if scanned % 50 == 0 {
                        DispatchQueue.main.async { self?.statusLabel.stringValue = "Searching \(url.lastPathComponent)… (\(scanned) files)" }
                    }
                    return !(self?.searchCancelled ?? true)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.searching = false
                self.spinner.stopAnimation(nil)
                self.searchButton.title = "Search Folder"
                switch result {
                case .failure(let e): self.statusLabel.stringValue = e.localizedDescription
                case .success(let hits):
                    let files = Set(hits.compactMap(\.url)).count
                    self.statusLabel.stringValue = "\(hits.count) matches in \(files) file\(files == 1 ? "" : "s") (\(scanned) searched)"
                    if hits.isEmpty { NSSound.beep(); return }
                    SearchResultsWindowController.show(title: "“\(opts.pattern)” in \(folder.lastPathComponent)",
                                                       hits: hits, document: nil, showFiles: true, root: folder)
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) { save() }
}
