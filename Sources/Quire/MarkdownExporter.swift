import AppKit
import PDFKit
import WebKit
import QuireCore

/// Renders a Markdown document off screen in WebKit, with the preview's highlighting, math
/// and diagrams, and turns the result into a self-contained HTML file, a paginated PDF,
/// rich text on the pasteboard or a print job. Exports always use the light theme.
final class MarkdownExporter: NSObject, WKNavigationDelegate {

    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Exporters keep themselves alive until they finish.
    private static var active: [ObjectIdentifier: MarkdownExporter] = [:]

    let document: MarkdownDocument
    let title: String
    let options: MarkdownExportOptions
    private let baseURL: URL?
    private let window: NSWindow
    private let webView: WKWebView
    private let pageFile: URL
    private var onLoad: ((Error?) -> Void)?
    private typealias Rendered = (body: String, fonts: [(family: String, weight: String, style: String)])
    /// Rendered bodies, light and (when needed) dark.
    private var renderedLight: Rendered?
    private var renderedDark: Rendered?

    /// `fileURL` is the Markdown file (for relative images and links); `name` is used as the
    /// title when the document has neither front matter `title` nor a heading.
    init(markdown: String, fileURL: URL?, name: String, options: MarkdownExportOptions) {
        self.options = options
        document = MarkdownDocument(markdown, options: MarkdownOptions(smartPunctuation: options.smartPunctuation, sanitizeHTML: options.sanitizeHTML))
        title = MarkdownExport.title(of: document, fallback: (name as NSString).deletingPathExtension)
        baseURL = fileURL?.deletingLastPathComponent()
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 1100), configuration: config)
        webView.appearance = NSAppearance(named: .aqua)
        // WebKit only lays out and prints from a view in a window; keep it far off screen.
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 820, height: 1100),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Quire/Export")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pageFile = dir.appendingPathComponent("\(UUID().uuidString).html")
        super.init()
        webView.navigationDelegate = self
    }

    private func retain() { Self.active[ObjectIdentifier(self)] = self }

    private func finish() {
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: pageFile)
        Self.active[ObjectIdentifier(self)] = nil
    }

    // MARK: Rendering

    /// Loads the page and waits for highlighting, math and diagrams to finish, in the light
    /// or dark colour scheme (diagrams are drawn for the scheme).
    private func render(dark: Bool = false, _ done: @escaping (Error?) -> Void) {
        if (dark ? renderedDark : renderedLight) != nil { done(nil); return }
        retain()
        guard let assets = PreviewPane.assets else { done(ExportError(message: "Quire's preview resources are missing.")); return }
        let body = MarkdownExport.body(document, title: title, options: options)
        let css = MarkdownExport.exportCSS + (options.linkAddresses ? "\n" + MarkdownExport.linkAddressCSS : "")
        let page = Markdown.page(body: body, title: title, baseURL: baseURL, assets: assets, extraCSS: css)
        do { try Data(page.utf8).write(to: pageFile) } catch { done(error); return }
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.orderFront(nil)
        var finished = false
        onLoad = { [weak self] error in
            guard let self else { return }
            if let error { finished = true; done(error); return }
            self.webView.callAsyncJavaScript("""
                if (window.quireReady) await window.quireReady;
                for (const b of document.querySelectorAll("pre .copy")) b.remove();
                await document.fonts.ready;
                const fonts = [];
                document.fonts.forEach(f => { if (f.status === "loaded") fonts.push([f.family.replace(/["']/g, ""), String(f.weight), f.style]); });
                return { body: document.body.innerHTML, fonts: fonts };
                """, arguments: [:], in: nil, in: .page) { [weak self] result in
                guard let self, !finished else { return }
                finished = true
                switch result {
                case .success(let value):
                    let dict = value as? [String: Any]
                    let fonts = (dict?["fonts"] as? [[String]] ?? []).compactMap { f in f.count == 3 ? (family: f[0], weight: f[1], style: f[2]) : nil }
                    let rendered: Rendered = ((dict?["body"] as? String) ?? "", fonts)
                    if dark { self.renderedDark = rendered } else { self.renderedLight = rendered }
                    done(nil)
                case .failure(let error):
                    done(error)
                }
            }
        }
        webView.loadFileURL(pageFile, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        // Give up if WebKit never finishes (e.g. a diagram library hangs).
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, !finished else { return }
            finished = true
            self.onLoad = nil
            done(ExportError(message: "Rendering the document timed out."))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let load = onLoad
        onLoad = nil
        load?(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let load = onLoad
        onLoad = nil
        load?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let load = onLoad
        onLoad = nil
        load?(error)
    }

    /// Links in exported content never navigate the off-screen view.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
    }

    // MARK: HTML

    /// The rendered document as one self-contained page: inline styles, embedded fonts and
    /// (depending on the options) images, diagrams as SVG, and no scripts.
    private func selfContainedHTML(images: MarkdownExportOptions.Images, filesDir: URL?, theme: MarkdownExportOptions.Theme) -> String {
        guard let base = theme == .dark ? renderedDark : renderedLight, let assets = PreviewPane.assets else { return "" }
        func read(_ path: String) -> String { (try? String(contentsOf: assets.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        var body = base.body
        let fonts = base.fonts
        var css: [String]
        var scheme = "light"
        switch theme {
        case .light:
            css = [MarkdownExport.lightOnly(Markdown.pageCSS), read("hljs/github.min.css")]
        case .dark:
            css = [MarkdownExport.darkOnly(Markdown.pageCSS), read("hljs/github-dark.min.css")]
            scheme = "dark"
        case .auto:
            if let dark = renderedDark {
                // Mermaid scopes each diagram's styles by its id; keep the two renderings apart.
                body = MarkdownExport.mergeDiagrams(light: body, dark: dark.body.replacingOccurrences(of: "quire-diagram-", with: "quire-diagram-dark-"))
            }
            css = [Markdown.pageCSS, MarkdownExport.onlyIn("light", read("hljs/github.min.css")),
                   MarkdownExport.onlyIn("dark", read("hljs/github-dark.min.css")), MarkdownExport.schemeSwitchCSS]
            scheme = "light dark"
        }
        if body.contains("class=\"katex") {
            css.append(MarkdownExport.katexCSS(read("katex/katex.min.css"), fonts: assets.appendingPathComponent("katex/fonts"), used: fonts))
        }
        let preview = read("quire-preview.css")
        css.append(theme == .light ? MarkdownExport.lightOnly(preview) : theme == .dark ? MarkdownExport.darkOnly(preview) : preview)
        css.append(MarkdownExport.exportCSS)
        if options.linkAddresses { css.append(MarkdownExport.linkAddressCSS) }
        body = MarkdownExport.processImages(body, base: baseURL, mode: images, filesDir: filesDir)
        return MarkdownExport.page(title: title, body: body, stylesheets: css, colorScheme: scheme)
    }

    /// Writes a self-contained HTML file. With `.copy` images, they go in `<name>_files` beside it.
    func exportHTML(to url: URL, _ done: @escaping (Error?) -> Void) {
        let theme = options.theme
        render(dark: theme == .dark) { [self] error in
            if let error { finish(); done(error); return }
            func write() {
                defer { finish() }
                let files = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_files")
                do {
                    try Data(selfContainedHTML(images: options.images, filesDir: files, theme: theme).utf8).write(to: url, options: .atomic)
                    done(nil)
                } catch { done(error) }
            }
            if theme == .auto {
                // A second pass draws the diagrams in dark colours too.
                render(dark: true) { [self] error in if let error { finish(); done(error) } else { write() } }
            } else {
                write()
            }
        }
    }

    /// The rendered page as HTML and RTF on the general pasteboard, plus the Markdown as plain text.
    func copyAsRichText(_ done: @escaping (Error?) -> Void) {
        render { [self] error in
            defer { finish() }
            if let error { done(error); return }
            let html = selfContainedHTML(images: .embed, filesDir: nil, theme: .light)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.declareTypes([.html, .rtf, .string], owner: nil)
            pb.setString(html, forType: .html)
            if let attributed = try? NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                                                                          .characterEncoding: String.Encoding.utf8.rawValue],
                                                        documentAttributes: nil),
               let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pb.setData(rtf, forType: .rtf)
            }
            pb.setString(document.source, forType: .string)
            done(nil)
        }
    }

    // MARK: PDF and printing

    /// Runs `body` once headings have been tied to the blocks after them.
    private func preparePrinting(_ body: @escaping () -> Void) {
        webView.evaluateJavaScript(MarkdownExport.keepHeadingsWithNextScript) { _, _ in body() }
    }

    private func printOperation(_ base: NSPrintInfo, headerAndFooter: Bool? = nil) -> NSPrintOperation {
        let info = base.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = headerAndFooter ?? options.pageNumbers
        let op = webView.printOperation(with: info)
        op.jobTitle = title
        // WKWebView's printing view starts with a zero frame, which prints blank pages.
        op.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        return op
    }

    /// Saves a paginated PDF using the paper size and margins in `printInfo`.
    func exportPDF(to url: URL, printInfo: NSPrintInfo, _ done: @escaping (Error?) -> Void) {
        render { [self] error in
            if let error { finish(); done(error); return }
            preparePrinting { [self] in
                let info = printInfo.copy() as! NSPrintInfo
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
                // Exported PDFs get plain page numbers (added below), not the system's title-and-date header.
                let op = printOperation(info, headerAndFooter: false)
                op.showsPrintPanel = false
                op.showsProgressPanel = false
                pdfDone = { [self] ok in
                    defer { finish() }
                    guard ok, let pdf = PDFDocument(url: url) else { done(ExportError(message: "The PDF could not be written.")); return }
                    var attrs = pdf.documentAttributes ?? [:]
                    attrs[PDFDocumentAttribute.titleAttribute] = title
                    if let author = MarkdownExport.frontMatterValue(document, "author") { attrs[PDFDocumentAttribute.authorAttribute] = author }
                    attrs[PDFDocumentAttribute.creatorAttribute] = "Quire"
                    pdf.documentAttributes = attrs
                    if options.pageNumbers { Self.addPageNumbers(to: pdf, skipFirst: options.titlePage) }
                    pdf.write(to: url)
                    done(nil)
                }
                op.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
            }
        }
    }

    /// Shows the print panel for the rendered page, attached to `window`.
    func print(printInfo: NSPrintInfo, from parent: NSWindow?, _ done: @escaping (Error?) -> Void) {
        render { [self] error in
            if let error { finish(); done(error); return }
            preparePrinting { [self] in
                let op = printOperation(printInfo)
                op.showsPrintPanel = true
                op.showsProgressPanel = true
                pdfDone = { [self] _ in finish(); done(nil) }
                op.runModal(for: parent ?? window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
            }
        }
    }

    private var pdfDone: ((Bool) -> Void)?

    /// "2 / 7" centred at the foot of each page (the title page, if any, is left blank and not counted).
    static func addPageNumbers(to pdf: PDFDocument, skipFirst: Bool) {
        let first = skipFirst ? 1 : 0
        let total = pdf.pageCount - first
        guard total > 0 else { return }
        for i in first..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let label = PDFAnnotation(bounds: NSRect(x: box.midX - 60, y: box.minY + 22, width: 120, height: 14), forType: .freeText, withProperties: nil)
            label.contents = "\(i - first + 1) / \(total)"
            label.font = NSFont.systemFont(ofSize: 9)
            label.fontColor = NSColor(white: 0.45, alpha: 1)
            label.color = .clear
            label.alignment = .center
            let border = PDFBorder()
            border.lineWidth = 0
            label.border = border
            label.isReadOnly = true
            page.addAnnotation(label)
        }
    }

    /// AppKit may call this on the print operation's own thread.
    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [self] in
            let done = pdfDone
            pdfDone = nil
            done?(success)
        }
    }
}
