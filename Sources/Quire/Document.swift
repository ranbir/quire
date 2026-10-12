import AppKit
import QuireCore

@objc(QuireDocument)
final class Document: NSDocument {
    /// Text as loaded from disk (LF line endings). The live text lives in the editor.
    private(set) var loadedText = ""
    var encoding: String.Encoding = .utf8
    var lineEnding: LineEnding = .lf
    var hasBOM = false
    var language: Language?
    /// Shell worksheets run lines in a persistent shell (⌘↩).
    var isWorksheet = false
    /// Set for files opened over SSH; the local file is a cached copy.
    var remote: RemoteLocation?

    private var _editor: EditorViewController?
    var editor: EditorViewController {
        if let e = _editor { return e }
        let e = EditorViewController(document: self)
        _editor = e
        _ = e.view
        return e
    }

    override class var autosavesInPlace: Bool { false }
    override class var readableTypes: [String] { ["public.data", "public.text"] }
    override class var writableTypes: [String] { ["public.plain-text"] }
    override class func isNativeType(_ type: String) -> Bool { true }

    var text: String { _editor?.textView.string ?? loadedText }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    /// Documents embedded in a project window have no window controllers of their own.
    override func showWindows() {
        if windowControllers.isEmpty, let project = ProjectWindowController.hosting(self) {
            project.show(self)
        } else {
            super.showWindows()
        }
    }

    override var windowForSheet: NSWindow? {
        if windowControllers.isEmpty, let project = ProjectWindowController.hosting(self) { return project.window }
        return super.windowForSheet
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let d = TextCodec.decode(data)
        loadedText = d.text
        encoding = d.encoding
        lineEnding = d.lineEnding
        hasBOM = d.hasBOM
        if fileURL?.pathExtension.lowercased() == "worksheet" { isWorksheet = true }
        let firstLine = d.text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        language = Languages.detect(filename: remote?.fileName ?? fileURL?.lastPathComponent, firstLine: firstLine)
        _editor?.reloadFromDocument()
    }

    /// Replaces the contents as if freshly loaded (used for remote files and scripting).
    func load(text: String) {
        loadedText = TextCodec.normalizeLineEndings(text)
        _editor?.reloadFromDocument()
    }

    override func data(ofType typeName: String) throws -> Data {
        _editor?.textView.breakUndoCoalescing()
        return try TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding, bom: hasBOM)
    }

    override var displayName: String! {
        get { remote?.display ?? super.displayName }
        set { super.displayName = newValue }
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowsOtherFileTypes = true
        savePanel.allowedContentTypes = []
        savePanel.isExtensionHidden = false
        if fileURL == nil {
            if isWorksheet {
                savePanel.nameFieldStringValue = "untitled.worksheet"
            } else if let ext = language?.extensions.first, language?.name != "Plain Text" {
                savePanel.nameFieldStringValue = "untitled.\(ext)"
            }
        }
        return true
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? { nil }

    override var fileURL: URL? {
        didSet {
            // Re-detect the language when an untitled document is first saved.
            if oldValue == nil, let url = fileURL, language == nil || language?.name == "Plain Text" {
                let detected = Languages.detect(filename: url.lastPathComponent, firstLine: nil)
                if detected.name != "Plain Text" { _editor?.setLanguage(detected) }
            }
        }
    }

    /// After a local save, push remote documents back to their server and
    /// refresh Git markers for local ones.
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            guard let self, error == nil else { completionHandler(error); return }
            guard let remote = self.remote, saveOperation != .autosaveElsewhereOperation, url == self.fileURL else {
                completionHandler(nil)
                self._editor?.refreshGit(reloadHead: true)
                return
            }
            let data = (try? Data(contentsOf: url)) ?? Data()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try RemoteFiles.client.write(data, to: remote) }
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        completionHandler(nil)
                    case .failure(let e):
                        self.updateChangeCount(.changeDone)   // still unsaved on the server
                        completionHandler(ProcessError("Saved locally, but uploading to \(remote.display) failed:\n\(e.localizedDescription)"))
                    }
                }
            }
        }
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = printInfo
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        view.string = text
        view.sizeToFit()
        return NSPrintOperation(view: view, printInfo: info)
    }

    /// Reload silently when the file changes on disk and there are no unsaved edits.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.remote == nil, let url = self.fileURL, !self.isDocumentEdited,
                  let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  let known = self.fileModificationDate, mod > known else { return }
            try? self.revert(toContentsOf: url, ofType: self.fileType ?? "public.plain-text")
        }
    }

    override func close() {
        stopShell()
        _editor?.preview?.close()
        super.close()
    }

    // MARK: Worksheet shell

    private var _shell: ShellSession?
    var shell: ShellSession {
        if let s = _shell { return s }
        let dir = fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        let s = ShellSession(directory: dir)
        _shell = s
        return s
    }
    var shellDirectory: URL? { _shell?.directory ?? fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser }
    func stopShell() { _shell?.terminate() }

    // MARK: AppleScript

    @objc var scriptContents: String {
        get { text }
        set {
            let tv = editor.textView
            tv.replace(NSRange(location: 0, length: (tv.string as NSString).length), with: TextCodec.normalizeLineEndings(newValue), select: false)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    @objc var scriptSelection: String {
        get { let tv = editor.textView; return (tv.string as NSString).substring(with: tv.selectedRange()) }
        set { editor.textView.replace(editor.textView.selectedRange(), with: TextCodec.normalizeLineEndings(newValue)) }
    }

    @objc var scriptLanguage: String {
        get { language?.name ?? Languages.plainText.name }
        set { editor.setLanguage(newValue == Languages.plainText.name ? Languages.plainText : Languages.named(newValue)) }
    }

    @objc var scriptLineCount: Int { LineIndex(text).lineCount }
    @objc var scriptPath: String? { fileURL?.path }
}

final class DocumentController: NSDocumentController {
    static let projectType = "local.quire.project"

    override func documentClass(forType typeName: String) -> AnyClass? {
        typeName == Self.projectType ? ProjectDocument.self : Document.self
    }

    override func typeForContents(of url: URL) throws -> String {
        if url.pathExtension.lowercased() == "quireproject" { return Self.projectType }
        return (try? super.typeForContents(of: url)) ?? "public.plain-text"
    }

    override var defaultType: String? { "public.plain-text" }

    /// Opens `url` (if needed) and puts the caret at a 1-based line.
    func open(_ url: URL, line: Int? = nil, column: Int = 0, length: Int = 0) {
        openDocument(withContentsOf: url, display: true) { doc, _, error in
            if let error { NSApp.presentError(error); return }
            if let line, let doc = doc as? Document {
                doc.editor.select(line: line, column: column, length: length)
            }
        }
    }
}
