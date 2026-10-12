import AppKit
import QuireCore

/// Anything that shows editors: a standalone editor window or a project window.
protocol EditorHost: AnyObject {
    var activeEditor: EditorViewController? { get }
}

extension NSApplication {
    /// The editor in the main window.
    var mainEditor: EditorViewController? {
        (mainWindow?.windowController as? EditorHost)?.activeEditor
    }

    /// The main window's editor, or the frontmost editor anywhere.
    var activeEditor: EditorViewController? {
        mainEditor ?? orderedWindows.lazy.compactMap { ($0.windowController as? EditorHost)?.activeEditor }.first
    }
}

/// A standalone window showing one document's editor.
final class EditorWindowController: NSWindowController, NSWindowDelegate, EditorHost {
    let editor: EditorViewController
    var activeEditor: EditorViewController? { editor }

    init(document: Document) {
        editor = document.editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "QuireEditor"
        window.minSize = NSSize(width: 360, height: 200)
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        editor.removeFromParent()
        editor.view.removeFromSuperview()
        window.contentViewController = editor
        if let frame = UserDefaults.standard.string(forKey: "lastWindowFrame") {
            window.setFrame(NSRectFromString(frame), display: false)
        } else {
            window.setContentSize(NSSize(width: 860, height: 680))
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowDidResize(_ notification: Notification) {
        if let f = window?.frame { UserDefaults.standard.set(NSStringFromRect(f), forKey: "lastWindowFrame") }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(editor.textView)
        editor.refreshGit(reloadHead: true)
    }
}

/// The editor for one document: text view, gutter, status bar, folding,
/// Git markers, worksheet execution and live preview. Embeddable in any window.
final class EditorViewController: NSViewController, NSTextViewDelegate, NSTextStorageDelegate, NSMenuDelegate, NSSplitViewDelegate {
    weak var doc: Document?
    let textView: EditorTextView
    let scrollView = NSScrollView()
    /// Holds the text and, when shown, the preview pane on its right.
    private let splitView = NSSplitView()
    let layoutManager = InvisiblesLayoutManager()
    let folds = FoldManager()
    private(set) var ruler: LineNumberRulerView!
    private var highlighter: SyntaxHighlighter!

    private let symbolPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let positionLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let previewButton = NSButton()
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let encodingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lineEndingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var observers: [NSObjectProtocol] = []

    private(set) var preview: PreviewPane?
    private var analysisWork: DispatchWorkItem?
    private var analysisGeneration = 0
    private var gitRepo: GitRepository?
    private var gitHead: String?
    private var gitBranch: String?
    private var worksheetInsertion: Int?

    init(document: Document) {
        self.doc = document
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        super.init(nibName: nil, bundle: nil)
        storage.delegate = self
        layoutManager.delegate = folds
        layoutManager.foldManager = folds
        folds.layoutManager = layoutManager
        textView.foldManager = folds
        folds.onChange = { [weak self] in
            self?.textView.needsDisplay = true
            self?.ruler?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    var displayName: String { doc?.displayName ?? "untitled" }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 680))
        buildUI()
        observers.append(NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyPrefs()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .languagesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildLanguagePopup()
        })
        reloadFromDocument()
    }

    // MARK: UI

    private func buildUI() {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.backgroundColor = Theme.background
        textView.drawsBackground = true
        textView.textColor = Theme.text
        textView.insertionPointColor = Theme.text
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        ruler.foldManager = folds
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            self?.ruler.needsDisplay = true
        })

        highlighter = SyntaxHighlighter(textView: textView, language: Languages.plainText)

        // Status bar
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox(); divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        for p in [symbolPopup, languagePopup, encodingPopup, lineEndingPopup] {
            p.controlSize = .small
            p.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            p.isBordered = false
            p.target = self
        }
        symbolPopup.menu?.delegate = self
        symbolPopup.addItem(withTitle: "ƒ Symbols")
        symbolPopup.toolTip = "Jump to a function, class or heading"

        positionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        positionLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        previewButton.bezelStyle = .inline
        previewButton.isBordered = false
        previewButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview")
        previewButton.imagePosition = .imageOnly
        previewButton.toolTip = "Show or hide the live preview (⌥⌘P)"
        previewButton.target = self
        previewButton.action = #selector(togglePreview(_:))

        rebuildLanguagePopup()
        languagePopup.action = #selector(languagePopupChanged(_:))
        languagePopup.toolTip = "Language"
        for enc in TextCodec.supportedEncodings {
            encodingPopup.addItem(withTitle: TextCodec.name(of: enc))
            encodingPopup.lastItem?.representedObject = enc.rawValue
        }
        encodingPopup.addItem(withTitle: "UTF-8 with BOM")
        encodingPopup.lastItem?.representedObject = "bom"
        encodingPopup.action = #selector(encodingPopupChanged(_:))
        encodingPopup.toolTip = "Text encoding used when saving"
        for le in LineEnding.allCases {
            lineEndingPopup.addItem(withTitle: le.displayName)
            lineEndingPopup.lastItem?.representedObject = le.rawValue
        }
        lineEndingPopup.action = #selector(lineEndingPopupChanged(_:))
        lineEndingPopup.toolTip = "Line breaks used when saving"

        let left = NSStackView(views: [symbolPopup, positionLabel, spinner, infoLabel])
        let right = NSStackView(views: [previewButton, languagePopup, encodingPopup, lineEndingPopup])
        for s in [left, right] { s.spacing = 12; s.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(s) }

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(scrollView)

        view.addSubview(splitView)
        view.addSubview(divider)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: divider.topAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 24),
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 8),
        ])
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        symbolPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func rebuildLanguagePopup() {
        let current = textView.language.name
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: Languages.names)
        languagePopup.selectItem(withTitle: current)
        // A reloaded module may have changed the current language's definition.
        if isViewLoaded, current != Languages.plainText.name { setLanguage(Languages.named(current)) }
    }

    // MARK: Document sync

    func reloadFromDocument() {
        guard isViewLoaded, let doc else { return }
        let oldSel = textView.selectedRange()
        let wasLoaded = !textView.string.isEmpty
        folds.reset()
        textView.string = doc.loadedText
        textView.undoManager?.removeAllActions()
        let len = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: wasLoaded ? min(oldSel.location, len) : 0, length: 0))
        setLanguage(doc.language ?? Languages.plainText)
        applyPrefs()
        syncStatusPopups()
        ruler.textDidChange()
        updatePosition()
        updateInfo()
        refreshGit(reloadHead: true)
        preview?.scheduleUpdate()
    }

    func setLanguage(_ lang: Language) {
        doc?.language = lang
        textView.language = lang
        languagePopup.selectItem(withTitle: lang.name)
        highlighter?.setLanguage(lang)
        scheduleAnalysis(immediately: true)
        previewButton.isHidden = !["Markdown", "HTML"].contains(lang.name)
        preview?.scheduleUpdate()
    }

    func syncStatusPopups() {
        guard let doc else { return }
        if doc.encoding == .utf8 && doc.hasBOM {
            encodingPopup.selectItem(at: encodingPopup.numberOfItems - 1)
        } else if let i = encodingPopup.itemArray.firstIndex(where: { ($0.representedObject as? UInt) == doc.encoding.rawValue }) {
            encodingPopup.selectItem(at: i)
        } else {
            encodingPopup.addItem(withTitle: TextCodec.name(of: doc.encoding))
            encodingPopup.lastItem?.representedObject = doc.encoding.rawValue
            encodingPopup.selectItem(at: encodingPopup.numberOfItems - 1)
        }
        lineEndingPopup.selectItem(withTitle: doc.lineEnding.displayName)
    }

    func applyPrefs() {
        guard isViewLoaded else { return }
        let font = Prefs.font
        textView.font = font
        textView.tabWidth = Prefs.tabWidth
        textView.expandTabs = Prefs.expandTabs
        textView.autoIndent = Prefs.autoIndent
        textView.autoComplete = Prefs.autoComplete
        textView.showPageGuide = Prefs.showPageGuide
        textView.pageGuideColumn = Prefs.pageGuideColumn
        textView.highlightCurrentLine = Prefs.highlightCurrentLine
        folds.capsuleWidth = ceil(textView.charWidth * 2.6 + 6)

        let para = NSMutableParagraphStyle()
        para.defaultTabInterval = textView.charWidth * CGFloat(Prefs.tabWidth)
        para.tabStops = []
        textView.defaultParagraphStyle = para
        textView.typingAttributes = [.font: font, .paragraphStyle: para, .foregroundColor: Theme.text]
        if let storage = textView.textStorage, storage.length > 0 {
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttributes([.font: font, .paragraphStyle: para, .foregroundColor: Theme.text], range: all)
            storage.endEditing()
        }

        layoutManager.showInvisibles = Prefs.showInvisibles
        setSoftWrap(Prefs.softWrap)
        scrollView.rulersVisible = Prefs.showLineNumbers
        ruler.textDidChange()
        textView.needsDisplay = true
        layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
    }

    private func setSoftWrap(_ wrap: Bool) {
        guard let container = textView.textContainer else { return }
        scrollView.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        container.widthTracksTextView = wrap
        if wrap {
            let w = scrollView.contentSize.width
            container.containerSize = NSSize(width: w - textView.textContainerInset.width * 2, height: .greatestFiniteMagnitude)
            textView.frame.size.width = w
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    // MARK: Text view & storage delegates

    func undoManager(for view: NSTextView) -> UndoManager? { doc?.undoManager }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        folds.textEdited(range: editedRange, delta: delta)
        if let ins = worksheetInsertion, editedRange.location < ins {
            worksheetInsertion = max(editedRange.location, ins + delta)
        }
    }

    func textDidChange(_ notification: Notification) {
        highlighter.scheduleHighlight()
        ruler.textDidChange()
        updatePosition()
        scheduleAnalysis()
        preview?.scheduleUpdate()
        textView.textDidChangeForCompletion()
    }

    func textViewDidChangeSelection(_ notification: Notification) { updatePosition() }

    func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        let prefix = (textView.string as NSString).substring(with: charRange)
        index?.pointee = -1
        return Completion.candidates(prefix: prefix, text: textView.string, language: self.textView.language)
    }

    private func updatePosition() {
        let sel = textView.selectedRange()
        let index = ruler.lineIndex
        let line = index.line(for: sel.location)
        let col = sel.location - index.starts[min(line, index.starts.count - 1)] + 1
        var s = "Ln \(line + 1), Col \(col)"
        if sel.length > 0 {
            let lines = index.line(for: NSMaxRange(sel)) - line + 1
            s += "  •  \(sel.length) chars" + (lines > 1 ? ", \(lines) lines" : "")
        }
        positionLabel.stringValue = s
    }

    private func updateInfo() {
        var parts: [String] = []
        if let branch = gitBranch { parts.append("⎇ \(branch)") }
        if doc?.isWorksheet == true, let dir = doc?.shellDirectory {
            parts.append("$ " + (dir.path as NSString).abbreviatingWithTildeInPath)
        }
        if let remote = doc?.remote { parts.append("☁︎ \(remote.destination)") }
        infoLabel.stringValue = parts.joined(separator: "   ")
    }

    // MARK: Folds and Git, recomputed in the background after edits

    private func scheduleAnalysis(immediately: Bool = false) {
        analysisWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.analyze() }
        analysisWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.5), execute: work)
    }

    private func analyze() {
        analysisGeneration += 1
        let gen = analysisGeneration
        let text = textView.string
        let lang = textView.language
        let head = gitHead
        guard (text as NSString).length < SyntaxHighlighter.maxLength else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let available = FoldScanner.folds(in: text, language: lang)
            let markers = head.map { LineDiff.changeMarkers(old: $0, new: text) } ?? [:]
            DispatchQueue.main.async {
                guard let self, gen == self.analysisGeneration else { return }
                self.folds.available = available
                self.ruler.gitMarkers = markers
                self.ruler.needsDisplay = true
            }
        }
    }

    /// Re-reads the HEAD version and branch (on load, save and window activation).
    func refreshGit(reloadHead: Bool) {
        guard reloadHead else { scheduleAnalysis(); return }
        guard let url = doc?.fileURL, doc?.remote == nil, Prefs.gitIntegration else {
            gitRepo = nil; gitHead = nil; gitBranch = nil; updateInfo(); scheduleAnalysis(immediately: true)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let repo = GitRepository.containing(url)
            let head = repo?.headContents(of: url)
            let branch = repo?.currentBranch()
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitRepo = repo; self.gitHead = head; self.gitBranch = branch
                self.updateInfo()
                self.scheduleAnalysis(immediately: true)
            }
        }
    }

    var repository: GitRepository? { gitRepo }
    var headText: String? { gitHead }

    // MARK: Folding commands

    @objc func foldSelection(_ sender: Any?) {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        guard sel.length > 0 else {
            // No selection: fold the innermost block around the caret.
            collapseEnclosingFold(sender); return
        }
        let firstLine = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let start = NSMaxRange(firstLine) - (ns.substring(with: firstLine).hasSuffix("\n") ? 1 : 0)
        var end = NSMaxRange(sel)
        if end > 0, ns.character(at: end - 1) == 10 { end -= 1 }
        guard end > start else { NSSound.beep(); return }
        folds.fold(NSRange(location: start, length: end - start))
        textView.setSelectedRange(NSRange(location: firstLine.location, length: 0))
    }

    @objc func unfoldSelection(_ sender: Any?) {
        let sel = textView.selectedRange()
        let lines = (textView.string as NSString).lineRange(for: sel)
        if !folds.unfold(intersecting: NSRange(location: lines.location, length: max(1, lines.length))) { NSSound.beep() }
    }

    @objc func collapseEnclosingFold(_ sender: Any?) {
        let loc = textView.selectedRange().location
        let candidates = folds.available.filter { NSLocationInRange(loc, $0.range) || loc == NSMaxRange($0.range) }
        guard let inner = candidates.min(by: { $0.range.length < $1.range.length }) else { NSSound.beep(); return }
        folds.fold(inner.range)
        let ns = textView.string as NSString
        textView.setSelectedRange(NSRange(location: ns.lineRange(for: NSRange(location: inner.range.location, length: 0)).location, length: 0))
    }

    @objc func collapseAllFolds(_ sender: Any?) {
        // Fold outermost regions only; nested ones are hidden with them.
        let sorted = folds.available.sorted { $0.range.location < $1.range.location }
        var lastEnd = -1
        for f in sorted where f.range.location >= lastEnd {
            folds.fold(f.range)
            lastEnd = NSMaxRange(f.range)
        }
        textView.setSelectedRange(NSRange(location: min(textView.selectedRange().location, sorted.first?.range.location ?? 0), length: 0))
    }

    @objc func expandAllFolds(_ sender: Any?) { folds.unfoldAll() }

    // MARK: Worksheet

    @objc func runWorksheetCommand(_ sender: Any?) {
        guard let doc else { return }
        guard worksheetInsertion == nil else { NSSound.beep(); return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let lines = ns.lineRange(for: sel)
        let command = (sel.length > 0 ? ns.substring(with: sel) : ns.substring(with: lines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { NSSound.beep(); return }

        var insertion = NSMaxRange(sel.length > 0 ? ns.lineRange(for: NSRange(location: NSMaxRange(sel) - 1, length: 0)) : lines)
        if insertion > ns.length { insertion = ns.length }
        worksheetInsertion = insertion
        spinner.startAnimation(nil)
        infoLabel.stringValue = "Running…"

        doc.shell.runAsync(command) { [weak self] result in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            let at = min(self.worksheetInsertion ?? insertion, (self.textView.string as NSString).length)
            self.worksheetInsertion = nil
            var output: String
            switch result {
            case .success(let o):
                output = o.text
                if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
                if o.timedOut { output += "[timed out]\n" } else if o.status != 0 { output += "[exit \(o.status)]\n" }
            case .failure(let e):
                output = "[\(e.localizedDescription)]\n"
            }
            let current = self.textView.string as NSString
            if at > 0 && at == current.length && current.character(at: at - 1) != 10 { output = "\n" + output }
            if !output.isEmpty {
                self.textView.replace(NSRange(location: at, length: 0), with: output)
                self.textView.scrollRangeToVisible(self.textView.selectedRange())
            }
            self.updateInfo()
        }
    }

    @objc func stopWorksheetCommand(_ sender: Any?) {
        doc?.stopShell()
    }

    // MARK: Preview

    private static let previewFractionKey = "PreviewPaneFraction"

    /// Shows the live preview in a pane to the right of the text.
    @objc func showPreview(_ sender: Any?) {
        if let preview { preview.update(); return }
        let pane = PreviewPane(editor: self)
        preview = pane
        splitView.addArrangedSubview(pane.view)
        splitView.layoutSubtreeIfNeeded()
        let saved = UserDefaults.standard.double(forKey: Self.previewFractionKey)
        let fraction = saved > 0.15 && saved < 0.85 ? saved : 0.5
        splitView.setPosition(splitView.bounds.width * fraction, ofDividerAt: 0)
        pane.update()
    }

    func hidePreview() {
        guard let preview else { return }
        preview.view.removeFromSuperview()
        self.preview = nil
        view.window?.makeFirstResponder(textView)
    }

    @objc func togglePreview(_ sender: Any?) {
        if preview == nil { showPreview(sender) } else { hidePreview() }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 200)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 200)
    }

    /// Window resizes keep the preview's share; the text keeps its width when the window is narrow.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard preview != nil, splitView.bounds.width > 400,
              (notification.userInfo?["NSSplitViewDividerIndex"]) != nil else { return }
        UserDefaults.standard.set(scrollView.frame.width / splitView.bounds.width, forKey: Self.previewFractionKey)
    }

    // MARK: Document actions forwarded from the responder chain
    // (needed when the editor is embedded in a project window).

    @objc func saveDocument(_ sender: Any?) { doc?.save(sender) }
    @objc func saveDocumentAs(_ sender: Any?) { doc?.saveAs(sender) }
    @objc func revertDocumentToSaved(_ sender: Any?) { doc?.revertToSaved(sender) }
    @objc func printDocument(_ sender: Any?) { doc?.printDocument(sender) }
    @objc func runPageLayout(_ sender: Any?) { doc?.runPageLayout(sender) }

    // MARK: Status bar actions

    @objc private func languagePopupChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        setLanguage(title == Languages.plainText.name ? Languages.plainText : Languages.named(title))
    }

    @objc func setLanguageFromMenu(_ sender: NSMenuItem) {
        setLanguage(sender.title == Languages.plainText.name ? Languages.plainText : Languages.named(sender.title))
    }

    @objc private func encodingPopupChanged(_ sender: NSPopUpButton) {
        guard let doc, let item = sender.selectedItem else { return }
        if (item.representedObject as? String) == "bom" {
            doc.encoding = .utf8; doc.hasBOM = true
        } else if let raw = item.representedObject as? UInt {
            doc.encoding = String.Encoding(rawValue: raw); doc.hasBOM = false
        }
        doc.updateChangeCount(.changeDone)
    }

    @objc private func lineEndingPopupChanged(_ sender: NSPopUpButton) {
        guard let doc, let raw = sender.selectedItem?.representedObject as? String, let le = LineEnding(rawValue: raw) else { return }
        doc.lineEnding = le
        doc.updateChangeCount(.changeDone)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === symbolPopup.menu else { return }
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }
        let symbols = SymbolScanner.symbols(in: textView.string, language: textView.language)
        if symbols.isEmpty {
            let item = menu.addItem(withTitle: "No symbols", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        let current = ruler.lineIndex.line(for: textView.selectedRange().location) + 1
        for s in symbols {
            let item = NSMenuItem(title: s.name, action: #selector(jumpToSymbol(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.location
            if s.line <= current { menu.items.forEach { $0.state = .off }; item.state = .on }
            menu.addItem(item)
        }
    }

    @objc private func jumpToSymbol(_ sender: NSMenuItem) {
        guard let loc = sender.representedObject as? Int else { return }
        folds.unfold(intersecting: NSRange(location: loc, length: 0))
        let r = (textView.string as NSString).lineRange(for: NSRange(location: loc, length: 0))
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        textView.scrollRangeToVisible(r)
        textView.showFindIndicator(for: r)
        view.window?.makeFirstResponder(textView)
    }

    // MARK: Helpers

    /// Brings this editor to the front, in whichever window hosts it.
    func reveal() {
        if let wc = doc?.windowControllers.first(where: { $0 is EditorWindowController }) {
            wc.showWindow(nil)
        } else if let doc, let project = ProjectWindowController.hosting(doc) {
            project.show(doc)
        }
    }

    func select(line: Int, column: Int, length: Int) {
        reveal()
        textView.selectLine(line, column: column, length: length)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setLanguageFromMenu(_:)):
            item.state = item.title == textView.language.name ? .on : .off
            return true
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(revertDocumentToSaved(_:)),
             #selector(printDocument(_:)), #selector(runPageLayout(_:)):
            return doc?.validateUserInterfaceItem(item) ?? false
        case #selector(togglePreview(_:)):
            item.title = preview == nil ? "Show Preview" : "Hide Preview"
            return true
        case #selector(stopWorksheetCommand(_:)):
            return worksheetInsertion != nil
        case #selector(runWorksheetCommand(_:)):
            return worksheetInsertion == nil
        case #selector(expandAllFolds(_:)):
            return !folds.folded.isEmpty
        default:
            return true
        }
    }
}
