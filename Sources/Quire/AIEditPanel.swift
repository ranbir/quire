import AppKit
import QuireCore

/// AI ▸ Edit with AI (⌘K): one sheet holding the instruction, the model, and a
/// syntax-coloured review of the result (original, result, or inline changes).
/// Follow-up instructions refine the previous result instead of starting over.
final class AIEditPanel: NSWindowController, NSTextViewDelegate {
    private enum Mode: Int { case original, result, changes }

    private static var open: [AIEditPanel] = []
    private static let recentKey = "recentAIInstructions"
    private static let suggestions = ["Add doc comments", "Simplify", "Fix bugs", "Add error handling", "Improve names"]

    private let editor: EditorTextView
    private let range: NSRange
    private let original: String
    private let documentBefore: String
    private let fileName: String?

    private let modelPopup = NSPopUpButton()
    private let prompt = PromptTextView()
    private let sendButton = NSButton()
    private let micButton = NSButton()
    private let dictation = Dictation()
    /// Prompt text from before dictation started; the transcript is appended to it.
    private var textBeforeDictation = ""
    private let recentButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let modeControl = NSSegmentedControl(labels: ["Original", "Result", "Changes"], trackingMode: .selectOne, target: nil, action: nil)
    private let code = NSTextView()
    private var highlighter: SyntaxHighlighter!
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)

    private var provider: AIProvider?
    private var history: [AIMessage] = []
    private var result: String?
    private var streaming = ""
    private var task: Task<Void, Never>?
    private var mode = Mode.original

    // MARK: Opening

    /// `instruction` pre-fills and runs the prompt (used by the snapshot hook).
    static func show(for editor: EditorViewController, instruction: String? = nil) {
        guard let window = editor.view.window, AIStore.readyProvider() != nil else { return }
        let panel = AIEditPanel(editor: editor)
        open.append(panel)
        window.beginSheet(panel.window!) { _ in open.removeAll { $0 === panel } }
        panel.window?.makeFirstResponder(panel.prompt)
        if let instruction {
            panel.prompt.string = instruction
            panel.generate()
        }
    }

    private init(editor ed: EditorViewController) {
        editor = ed.textView
        let sel = editor.selectedRange()
        let ns = editor.string as NSString
        range = sel.length > 0 ? sel : NSRange(location: 0, length: ns.length)
        original = ns.substring(with: range)
        documentBefore = editor.string
        fileName = ed.doc?.fileURL?.lastPathComponent

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.minSize = NSSize(width: 560, height: 420)
        super.init(window: w)
        build(selection: sel.length > 0)
        reloadModels()
        show(.original)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func build(selection: Bool) {
        guard let content = window?.contentView else { return }

        // Header: title, what's being edited, model picker
        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "Edit with AI")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let lines = LineIndex(editor.string)
        let first = lines.line(for: range.location) + 1
        let last = lines.line(for: max(range.location, NSMaxRange(range) - 1)) + 1
        let what = selection ? (first == last ? "Line \(first)" : "Lines \(first)–\(last)") : "Whole document · \(last) lines"
        let context = NSTextField(labelWithString: [what, editor.language.name, fileName].compactMap { $0 }.joined(separator: " · "))
        context.textColor = .secondaryLabelColor
        context.font = .systemFont(ofSize: 11)
        context.lineBreakMode = .byTruncatingMiddle
        let titles = NSStackView(views: [title, context])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        modelPopup.controlSize = .small
        modelPopup.font = .systemFont(ofSize: 11)
        let header = row([icon, titles, flexible(), modelPopup])
        header.alignment = .centerY

        // Instruction box with send button
        prompt.font = .systemFont(ofSize: 14)
        prompt.isRichText = false
        prompt.allowsUndo = true
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.textContainerInset = NSSize(width: 6, height: 8)
        prompt.backgroundColor = .textBackgroundColor
        prompt.delegate = self
        prompt.onSubmit = { [weak self] in self?.submit() }
        prompt.autoresizingMask = [.width]
        let promptScroll = NSScrollView()
        promptScroll.documentView = prompt
        promptScroll.hasVerticalScroller = true
        promptScroll.autohidesScrollers = true
        promptScroll.borderType = .noBorder
        promptScroll.drawsBackground = false
        sendButton.bezelStyle = .regularSquare
        sendButton.isBordered = false
        sendButton.imageScaling = .scaleProportionallyUpOrDown
        sendButton.target = self
        sendButton.action = #selector(sendOrStop(_:))
        sendButton.contentTintColor = .controlAccentColor
        micButton.bezelStyle = .regularSquare
        micButton.isBordered = false
        micButton.imageScaling = .scaleProportionallyUpOrDown
        micButton.target = self
        micButton.action = #selector(toggleDictation(_:))
        micButton.keyEquivalent = "m"
        micButton.keyEquivalentModifierMask = [.command, .shift]
        setUpDictation()
        let promptBox = NSBox()
        promptBox.boxType = .custom
        promptBox.cornerRadius = 8
        promptBox.borderWidth = 1
        promptBox.borderColor = .separatorColor
        promptBox.fillColor = .textBackgroundColor
        promptBox.contentViewMargins = .zero
        let boxContent = NSView()
        promptBox.contentView = boxContent
        for v in [promptScroll, micButton, sendButton] { v.translatesAutoresizingMaskIntoConstraints = false; boxContent.addSubview(v) }
        NSLayoutConstraint.activate([
            promptScroll.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor, constant: 2),
            promptScroll.topAnchor.constraint(equalTo: boxContent.topAnchor, constant: 2),
            promptScroll.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor, constant: -2),
            promptScroll.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -4),
            micButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            micButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 22),
            micButton.heightAnchor.constraint(equalToConstant: 22),
            sendButton.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor, constant: -8),
            sendButton.widthAnchor.constraint(equalToConstant: 26),
            sendButton.heightAnchor.constraint(equalToConstant: 26),
            promptBox.heightAnchor.constraint(equalToConstant: 84),
        ])

        // Suggestions and recent instructions
        var chips: [NSView] = Self.suggestions.map { s in
            let b = NSButton(title: s, target: self, action: #selector(useSuggestion(_:)))
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.showsBorderOnlyWhileMouseInside = false
            return b
        }
        recentButton.controlSize = .small
        recentButton.font = .systemFont(ofSize: 11)
        recentButton.bezelStyle = .recessed
        recentButton.target = self
        recentButton.action = #selector(useRecent(_:))
        rebuildRecent()
        chips += [flexible(), recentButton]
        let chipRow = row(chips)
        chipRow.spacing = 6

        // Review area
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.controlSize = .small
        let legend = NSTextField(labelWithString: "")
        legend.font = .systemFont(ofSize: 11)
        legend.textColor = .secondaryLabelColor
        code.isEditable = false
        code.isRichText = false
        code.allowsUndo = true
        code.font = Prefs.font
        code.textColor = Theme.text
        code.backgroundColor = Theme.background
        code.textContainerInset = NSSize(width: 8, height: 8)
        code.isAutomaticQuoteSubstitutionEnabled = false
        code.isAutomaticDashSubstitutionEnabled = false
        code.isAutomaticTextReplacementEnabled = false
        code.isContinuousSpellCheckingEnabled = false
        code.delegate = self
        code.autoresizingMask = [.width]
        code.isHorizontallyResizable = false
        code.textContainer?.widthTracksTextView = true
        highlighter = SyntaxHighlighter(textView: code, language: editor.language)
        let codeScroll = NSScrollView()
        codeScroll.documentView = code
        codeScroll.hasVerticalScroller = true
        codeScroll.borderType = .lineBorder
        codeScroll.setContentHuggingPriority(.init(1), for: .vertical)

        // Footer
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        copyButton.target = self; copyButton.action = #selector(copyResult(_:))
        replaceButton.target = self; replaceButton.action = #selector(accept(_:))
        replaceButton.keyEquivalent = "\r"
        replaceButton.toolTip = "Replace the \(selection ? "selection" : "document") with the result (↩ with an empty instruction, or ⌘↩). Undo restores it."
        let footer = row([spinner, statusLabel, flexible(), copyButton, cancel, replaceButton])

        let stack = NSStackView(views: [header, promptBox, chipRow, modeControl, codeScroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: header)
        stack.setCustomSpacing(16, after: chipRow)
        stack.setCustomSpacing(6, after: modeControl)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        for v in [header, promptBox, chipRow, codeScroll, footer] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        updateControls()
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func flexible() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    // MARK: State

    private func reloadModels() {
        modelPopup.removeAllItems()
        let list = AIStore.list
        for p in list.providers where !p.model.isEmpty {
            modelPopup.addItem(withTitle: "\(p.name) · \(p.model)")
            modelPopup.lastItem?.representedObject = p.id
        }
        provider = list.defaultProvider
        if let id = provider?.id, let i = modelPopup.itemArray.firstIndex(where: { $0.representedObject as? String == id }) {
            modelPopup.selectItem(at: i)
        }
    }

    private var isRunning: Bool { task != nil }

    private func updateControls() {
        let symbol = isRunning ? "stop.circle.fill" : "arrow.up.circle.fill"
        sendButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isRunning ? "Stop" : "Generate")?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        sendButton.toolTip = isRunning ? "Stop" : (result == nil ? "Generate (↩)" : "Refine the result (↩)")
        sendButton.isEnabled = isRunning || !prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let listening = dictation.isListening
        micButton.image = NSImage(systemSymbolName: listening ? "mic.circle.fill" : "mic", accessibilityDescription: listening ? "Stop dictation" : "Dictate")?
            .withSymbolConfiguration(.init(pointSize: listening ? 20 : 17, weight: .regular))
        micButton.contentTintColor = listening ? .systemRed : .secondaryLabelColor
        micButton.toolTip = listening ? "Stop dictation (⇧⌘M)" : "Speak the instruction (⇧⌘M)"
        micButton.isEnabled = !isRunning
        modelPopup.isEnabled = !isRunning
        modeControl.setEnabled(result != nil || isRunning, forSegment: Mode.result.rawValue)
        modeControl.setEnabled(result != nil, forSegment: Mode.changes.rawValue)
        replaceButton.isEnabled = result != nil && !isRunning
        copyButton.isEnabled = result != nil && !isRunning
        let target = range.length < (documentBefore as NSString).length ? "selection" : "document"
        prompt.placeholder = listening ? "Listening…  speak your instruction"
                           : result == nil ? "Describe how to change the \(target)…   ↩ generate  ·  ⇧↩ new line"
                                           : "Type a follow-up to refine…   or press ↩ to replace the \(target)"
        prompt.placeholderHidden = !prompt.string.isEmpty
    }

    private func show(_ m: Mode) {
        mode = m
        modeControl.selectedSegment = m.rawValue
        code.isEditable = m == .result && result != nil && !isRunning
        let lm = code.layoutManager
        let full = NSRange(location: 0, length: (code.string as NSString).length)
        lm?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        switch m {
        case .original: setCode(original)
        case .result: setCode(isRunning ? streaming : (result ?? ""))
        case .changes:
            let diff = LineDiff.interleaved(old: original, new: result ?? "")
            setCode(diff.text)
            for c in diff.changes {
                lm?.addTemporaryAttribute(.backgroundColor, value: c.kind == .inserted ? Self.insertedColor : Self.deletedColor, forCharacterRange: c.range)
            }
            if let firstChange = diff.changes.first { code.scrollRangeToVisible(firstChange.range) }
        }
    }

    private static let insertedColor = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.18, green: 0.42, blue: 0.24, alpha: 0.45) : NSColor(srgbRed: 0.80, green: 0.95, blue: 0.82, alpha: 1)
    }
    private static let deletedColor = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.55, green: 0.18, blue: 0.18, alpha: 0.45) : NSColor(srgbRed: 0.99, green: 0.85, blue: 0.85, alpha: 1)
    }

    private func setCode(_ s: String) {
        guard code.string != s else { return }
        code.string = s
        code.font = Prefs.font
        code.textColor = Theme.text
        highlighter.highlightNow()
    }

    private func setStatus(_ s: String, error: Bool = false) {
        statusLabel.stringValue = s
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    // MARK: Generating

    /// ↩ in the instruction box: refine/generate when there's text, accept the result when it's empty; ⌘↩ always accepts.
    private func submit() {
        let empty = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let command = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if result != nil && !isRunning && (empty || command) { accept(nil) } else { generate() }
    }

    @objc private func sendOrStop(_ sender: Any?) {
        if isRunning { stop() } else { generate() }
    }

    private func generate() {
        if dictation.isListening { dictation.stop() }
        let instruction = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !instruction.isEmpty, let provider else { NSSound.beep(); return }
        let key = AIStore.key(for: provider)   // first use per session may ask for Keychain access
        if provider.needsKey && (key ?? "").isEmpty { setStatus("“\(provider.name)” needs an API key — add it in AI Models (⌘,).", error: true); return }
        remember(instruction)

        if let result, !history.isEmpty {
            history.append(AIMessage(.assistant, result))
            history.append(AIMessage(.user, "Revise your last result: \(instruction)\n\nReply with the complete revised text only."))
        } else {
            history = [AIMessage(.user, AIText.transformPrompt(instruction: instruction, text: original, language: editor.language.name, fileName: fileName))]
        }
        let request = AIRequest(system: AIText.transformSystemPrompt, messages: history)
        streaming = ""
        spinner.startAnimation(nil)
        setStatus("Generating with \(provider.model)…")
        let started = Date()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await chunk in AIClient.stream(provider, apiKey: key, request) {
                    streaming += chunk
                    if mode != .result { show(.result) }
                    code.textStorage?.append(NSAttributedString(string: chunk, attributes: [.font: Prefs.font, .foregroundColor: Theme.text]))
                    code.scrollToEndOfDocument(nil)
                    highlighter.scheduleHighlight()
                }
                let text = AIText.stripFence(streaming, matchTrailingNewlineOf: original)
                result = text
                task = nil
                let secs = String(format: "%.1f", Date().timeIntervalSince(started))
                let changed = LineDiff.interleaved(old: original, new: text).changes
                let added = changed.filter { $0.kind == .inserted }.count, removed = changed.count - added
                setStatus(changed.isEmpty ? "No changes · \(provider.model) · \(secs)s"
                                          : "+\(added) −\(removed) lines · \(provider.model) · \(secs)s · type a follow-up to refine")
                show(changed.isEmpty ? .result : .changes)
                prompt.string = ""
            } catch is CancellationError {
                task = nil
                if history.count > 1 { history.removeLast(2) } else { history = [] }
                setStatus("Stopped.")
                show(result == nil ? .original : .result)
            } catch {
                task = nil
                if history.count > 1 { history.removeLast(2) } else { history = [] }
                setStatus(error.localizedDescription, error: true)
                show(result == nil ? .original : .result)
            }
            spinner.stopAnimation(nil)
            updateControls()
            window?.makeFirstResponder(prompt)
        }
        updateControls()
    }

    private func stop() {
        task?.cancel()
    }

    private func remember(_ instruction: String) {
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        recent.removeAll { $0 == instruction }
        recent.insert(instruction, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(12)), forKey: Self.recentKey)
        rebuildRecent()
    }

    private func rebuildRecent() {
        recentButton.removeAllItems()
        recentButton.addItem(withTitle: "Recent")
        let recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        for r in recent { recentButton.addItem(withTitle: r.count > 70 ? String(r.prefix(70)) + "…" : r); recentButton.lastItem?.representedObject = r }
        recentButton.isEnabled = !recent.isEmpty
    }

    // MARK: Dictation

    private func setUpDictation() {
        // Names from the code being edited help the recognizer spell identifiers.
        let words = Set(original.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init).filter { $0.count > 2 })
        let jargon = ["async", "await", "async/await", "struct", "enum", "protocol", "closure", "refactor", "JSON", "API",
                      "URL", "nil", "null", "boolean", "regex", "TODO", "doc comments", "unit tests", "error handling", "Codable"]
        dictation.contextualStrings = jargon + Array(words).sorted()
        dictation.onListeningChanged = { [weak self] listening in
            guard let self else { return }
            if listening {
                let t = prompt.string
                textBeforeDictation = t.isEmpty || t.hasSuffix(" ") || t.hasSuffix("\n") ? t : t + " "
                setStatus("Listening… pause when you’re done, or click the mic to stop.")
                window?.makeFirstResponder(prompt)
            } else if statusLabel.stringValue.hasPrefix("Listening") {
                setStatus(prompt.string.isEmpty ? "" : "Press ↩ to generate, or keep editing the instruction.")
            }
            updateControls()
        }
        dictation.onTranscript = { [weak self] text in
            guard let self else { return }
            prompt.string = textBeforeDictation + text
            prompt.setSelectedRange(NSRange(location: (prompt.string as NSString).length, length: 0))
            prompt.scrollToEndOfDocument(nil)
            updateControls()
        }
        dictation.onStatus = { [weak self] message in self?.setStatus(message) }
        dictation.onError = { [weak self] message in
            self?.setStatus(message, error: true)
            self?.updateControls()
        }
    }

    @objc private func toggleDictation(_ sender: Any?) {
        guard !isRunning else { NSSound.beep(); return }
        dictation.toggle()
    }

    // MARK: Actions

    @objc private func useSuggestion(_ sender: NSButton) {
        prompt.string = sender.title
        updateControls()
        generate()
    }

    @objc private func useRecent(_ sender: NSPopUpButton) {
        guard let s = sender.selectedItem?.representedObject as? String else { return }
        prompt.string = s
        prompt.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
        window?.makeFirstResponder(prompt)
        updateControls()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        var list = AIStore.list
        list.defaultID = id
        AIStore.list = list
        provider = list.defaultProvider
        setStatus("Using \(provider?.name ?? "") · \(provider?.model ?? "")")
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        show(Mode(rawValue: sender.selectedSegment) ?? .original)
    }

    @objc private func copyResult(_ sender: Any?) {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        setStatus("Copied.")
    }

    @objc private func accept(_ sender: Any?) {
        guard let result, !isRunning else { return }
        dictation.cancel()
        guard editor.string == documentBefore else {
            NSSound.beep()
            setStatus("The document changed since you started — copy the result instead.", error: true)
            return
        }
        editor.replace(range, with: result, select: range.length < (documentBefore as NSString).length)
        close(.OK)
    }

    @objc private func cancel(_ sender: Any?) {
        dictation.cancel()
        task?.cancel()
        close(.cancel)
    }

    private func close(_ code: NSApplication.ModalResponse) {
        guard let w = window, let parent = w.sheetParent else { return }
        parent.endSheet(w, returnCode: code)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        if (notification.object as? NSTextView) === code, mode == .result, result != nil {
            result = code.string   // hand edits to the result are kept
            highlighter.scheduleHighlight()
        }
        updateControls()
    }
}

/// The instruction field: ↩ submits, ⇧↩ / ⌥↩ insert a newline, and it draws a placeholder.
final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderHidden = false { didSet { if oldValue != placeholderHidden { needsDisplay = true } } }

    override func insertNewline(_ sender: Any?) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) || flags.contains(.option) { super.insertNewlineIgnoringFieldEditor(sender) } else { onSubmit?() }
    }

    override func didChangeText() {
        super.didChangeText()
        placeholderHidden = !string.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderHidden || string.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
    }
}

extension EditorViewController {
    /// AI ▸ Edit with AI: the selection (or whole document) plus an instruction
    /// goes to the chosen model; the reply replaces it only when accepted.
    @objc func transformWithAI(_ sender: Any?) {
        AIEditPanel.show(for: self)
    }
}
