import AppKit
import UniformTypeIdentifiers
import QuireCore

/// File ▸ Export, Edit ▸ Copy as Rich Text and rendered printing for Markdown documents.
extension EditorViewController {

    var isMarkdown: Bool { textView.language.name == "Markdown" }

    private func makeExporter(_ options: MarkdownExportOptions) -> MarkdownExporter {
        MarkdownExporter(markdown: textView.string, fileURL: doc?.fileURL, name: displayName, options: options)
    }

    private func report(_ error: Error?) {
        guard let error, let window = view.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    @objc func exportHTML(_ sender: Any?) {
        runExportPanel(kind: .html) { [weak self] url, options in
            self?.makeExporter(options).exportHTML(to: url) { self?.report($0) }
        }
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let info = doc?.printInfo else { return }
        runExportPanel(kind: .pdf) { [weak self] url, options in
            self?.makeExporter(options).exportPDF(to: url, printInfo: info) { self?.report($0) }
        }
    }

    @objc func copyAsRichText(_ sender: Any?) {
        makeExporter(ExportPrefs.load()).copyAsRichText { [weak self] in self?.report($0) }
    }

    /// Prints Markdown as its rendered page; other files print their text.
    @objc func printDocument(_ sender: Any?) {
        guard isMarkdown, let doc else { doc?.printDocument(sender); return }
        makeExporter(ExportPrefs.load()).print(printInfo: doc.printInfo, from: view.window) { [weak self] in self?.report($0) }
    }

    @objc func printSource(_ sender: Any?) { doc?.printDocument(sender) }

    @objc func toggleSmartPunctuation(_ sender: Any?) {
        Prefs.smartPunctuation.toggle()
    }

    /// Asks where pasted and dropped images go, relative to the document.
    @objc func chooseImagesFolder(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Folder for pasted and dropped images"
        alert.informativeText = "A folder name relative to each Markdown document, such as “assets” or “images/notes”. Leave it empty to save images next to the document."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = Prefs.markdownImagesFolder
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            Prefs.markdownImagesFolder = name == "." ? "" : name
        }
    }

    // MARK: Save panel

    enum ExportKind { case html, pdf }

    private func runExportPanel(kind: ExportKind, _ export: @escaping (URL, MarkdownExportOptions) -> Void) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind == .html ? .html : .pdf]
        panel.canCreateDirectories = true
        let base = doc?.fileURL?.deletingPathExtension().lastPathComponent ?? (displayName as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + (kind == .html ? ".html" : ".pdf")
        if let dir = doc?.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        let accessory = ExportAccessory(kind: kind, options: ExportPrefs.load())
        panel.accessoryView = accessory.view
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let options = accessory.options
            ExportPrefs.save(options)
            export(url, options)
        }
    }
}

/// Export choices, remembered between exports.
enum ExportPrefs {
    static func load() -> MarkdownExportOptions {
        let d = UserDefaults.standard
        var o = MarkdownExportOptions()
        o.images = d.string(forKey: "ExportImages").flatMap(MarkdownExportOptions.Images.init(rawValue:)) ?? .embed
        o.sanitizeHTML = d.bool(forKey: "ExportSanitizeHTML")
        o.tableOfContents = d.bool(forKey: "ExportTableOfContents")
        o.titlePage = d.bool(forKey: "ExportTitlePage")
        o.pageNumbers = d.object(forKey: "ExportPageNumbers") as? Bool ?? true
        o.linkAddresses = d.bool(forKey: "ExportLinkAddresses")
        o.theme = d.string(forKey: "ExportTheme").flatMap(MarkdownExportOptions.Theme.init(rawValue:)) ?? .light
        o.smartPunctuation = Prefs.smartPunctuation
        return o
    }

    static func save(_ o: MarkdownExportOptions) {
        let d = UserDefaults.standard
        d.set(o.images.rawValue, forKey: "ExportImages")
        d.set(o.sanitizeHTML, forKey: "ExportSanitizeHTML")
        d.set(o.tableOfContents, forKey: "ExportTableOfContents")
        d.set(o.titlePage, forKey: "ExportTitlePage")
        d.set(o.pageNumbers, forKey: "ExportPageNumbers")
        d.set(o.linkAddresses, forKey: "ExportLinkAddresses")
        d.set(o.theme.rawValue, forKey: "ExportTheme")
    }
}

/// The options shown under the save panel.
final class ExportAccessory {
    let view: NSView
    private let images = NSPopUpButton()
    private let toc = NSButton(checkboxWithTitle: "Table of contents", target: nil, action: nil)
    private let sanitize = NSButton(checkboxWithTitle: "Remove unsafe HTML (scripts, iframes, styles)", target: nil, action: nil)
    private let titlePage = NSButton(checkboxWithTitle: "Title page from front matter", target: nil, action: nil)
    private let pageNumbers = NSButton(checkboxWithTitle: "Page numbers", target: nil, action: nil)
    private let linkAddresses = NSButton(checkboxWithTitle: "Print link addresses after links", target: nil, action: nil)
    private let theme = NSPopUpButton()
    private let kind: EditorViewController.ExportKind
    private var base: MarkdownExportOptions

    init(kind: EditorViewController.ExportKind, options: MarkdownExportOptions) {
        self.kind = kind
        base = options
        images.addItems(withTitles: ["Embed in the page", "Link to the originals", "Copy to a folder beside the page"])
        images.selectItem(at: [.embed, .link, .copy].firstIndex(of: options.images) ?? 0)
        toc.state = options.tableOfContents ? .on : .off
        sanitize.state = options.sanitizeHTML ? .on : .off
        titlePage.state = options.titlePage ? .on : .off
        pageNumbers.state = options.pageNumbers ? .on : .off
        linkAddresses.state = options.linkAddresses ? .on : .off
        theme.addItems(withTitles: ["Light", "Dark", "Match the reader’s system"])
        theme.selectItem(at: MarkdownExportOptions.Theme.allCases.firstIndex(of: options.theme) ?? 0)

        var rows: [NSView] = []
        if kind == .html {
            rows.append(NSStackView(views: [NSTextField(labelWithString: "Images:"), images]))
            rows.append(NSStackView(views: [NSTextField(labelWithString: "Colours:"), theme]))
            rows += [toc, sanitize]
        } else {
            let note = NSTextField(labelWithString: "Paper size and margins come from File ▸ Page Setup.")
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            rows += [toc, titlePage, pageNumbers, linkAddresses, sanitize, note]
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        view = stack
    }

    var options: MarkdownExportOptions {
        var o = base
        if kind == .html {
            o.images = [.embed, .link, .copy][max(images.indexOfSelectedItem, 0)]
            o.theme = MarkdownExportOptions.Theme.allCases[max(theme.indexOfSelectedItem, 0)]
        }
        o.tableOfContents = toc.state == .on
        o.sanitizeHTML = sanitize.state == .on
        if kind == .pdf {
            o.titlePage = titlePage.state == .on
            o.pageNumbers = pageNumbers.state == .on
            o.linkAddresses = linkAddresses.state == .on
        }
        return o
    }
}
