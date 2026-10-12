import AppKit
import WebKit
import QuireCore

/// Live HTML / Markdown / code preview shown in a pane beside the editor. It follows
/// the editor as you type, keeping its scroll position across refreshes.
final class PreviewPane: NSViewController, WKNavigationDelegate {
    private weak var editor: EditorViewController?
    private let webView: WKWebView
    private var pending: DispatchWorkItem?
    private var savedScroll: CGFloat = 0
    private let tempFile: URL
    /// Identifies the page currently loaded; while it matches, updates swap the body in place.
    private var loadedShell: String?
    private var pendingShell: String?
    private var scrollRelay: ScrollMessageRelay?
    /// Set while the editor is being scrolled to follow the preview, so it doesn't echo back.
    private var followingPreview = false
    /// The editor follows the preview only while the pointer is over it (tests turn this off).
    var followRequiresPointer = true

    /// Highlighting, math and diagram libraries: in the app bundle, or in the source tree when
    /// running from `swift build`.
    static let assets: URL? = {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("preview"),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                            .appendingPathComponent("../../Resources/preview").standardized]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("quire-preview.js").path)
        }
    }()

    /// highlight.js names for Quire languages whose lowercased name doesn't match.
    private static let highlightNames = ["C++": "cpp", "Objective-C": "objectivec", "Shell Script": "bash",
                                         "INI / Config": "ini", "Plain Text": ""]

    init(editor: EditorViewController) {
        self.editor = editor
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let relay = ScrollMessageRelay()
        config.userContentController.add(relay, name: "quireScroll")
        webView = WKWebView(frame: .zero, configuration: config)
        scrollRelay = relay
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Quire/Preview")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempFile = dir.appendingPathComponent("\(UUID().uuidString).html")
        super.init(nibName: nil, bundle: nil)
        scrollRelay?.onMessage = { [weak self] body in self?.previewDidScroll(body) }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { try? FileManager.default.removeItem(at: tempFile) }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        // Header: title, Open in Browser, close
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Preview")
        title.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        title.textColor = .secondaryLabelColor
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: action)
            b.bezelStyle = .inline
            b.isBordered = false
            b.toolTip = tip
            return b
        }
        let browser = button("safari", "Open in Browser", #selector(openInBrowser(_:)))
        browser.target = self
        let close = button("xmark", "Hide Preview (⌥⌘P)", #selector(EditorViewController.togglePreview(_:)))
        close.target = editor
        let buttons = NSStackView(views: [browser, close])
        buttons.spacing = 10
        for v in [title, buttons] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(v) }
        let divider = NSBox(); divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(divider)
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func scheduleUpdate() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.update() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// The preview of the editor's current text: a full page, plus (for Markdown and code,
    /// which share one page template) the body and a key for the page it can be swapped into.
    private struct Rendered { var page: String; var body: String? = nil; var shell: String? = nil }

    private func render() -> Rendered {
        guard let editor else { return Rendered(page: "") }
        let text = editor.textView.string
        let base = editor.doc?.fileURL?.deletingLastPathComponent()
        let language = editor.textView.language.name
        let body: String
        switch language {
        case "HTML":
            guard let base else { return Rendered(page: text) }
            // Resolve relative links against the document's folder.
            let tag = "<base href=\"\(Markdown.escape(base.absoluteString))\">"
            if let r = text.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                return Rendered(page: text.replacingCharacters(in: r, with: text[r] + tag))
            }
            return Rendered(page: tag + text)
        case "Markdown":
            body = MarkdownDocument(text, options: MarkdownOptions(smartPunctuation: Prefs.smartPunctuation)).html(sourcePositions: true)
        default:
            let name = Self.highlightNames[language] ?? language.lowercased()
            let cls = name.isEmpty ? "" : " class=\"language-\(Markdown.escape(name))\""
            body = "<pre class=\"source\"><code\(cls)>\(Markdown.escape(text))</code></pre>"
        }
        let page = Markdown.page(body: body, title: editor.displayName, baseURL: base, assets: Self.assets)
        let shell = Self.assets == nil ? nil : "\(base?.path ?? "")\u{0}\(editor.displayName)"
        return Rendered(page: page, body: body, shell: shell)
    }

    private func renderHTML() -> String { render().page }

    func update() {
        guard editor != nil else { return }
        let rendered = render()
        if let body = rendered.body, let shell = rendered.shell, shell == loadedShell {
            // Same page template: swap the body in place, keeping scroll and rendered diagrams.
            webView.callAsyncJavaScript("await quireUpdate(html)", arguments: ["html": body], in: nil, in: .page) { [weak self] result in
                if case .failure = result { self?.loadedShell = nil; self?.load(rendered) } else { self?.syncScroll() }
            }
            return
        }
        load(rendered)
    }

    private func load(_ rendered: Rendered) {
        webView.evaluateJavaScript("window.scrollY") { [weak self] y, _ in
            guard let self else { return }
            if let y = y as? CGFloat { self.savedScroll = y }
            try? Data(rendered.page.utf8).write(to: self.tempFile)
            self.loadedShell = nil
            self.pendingShell = rendered.shell
            // Read access to "/" lets relative images and stylesheets load from the document's folder.
            self.webView.loadFileURL(self.tempFile, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
    }

    // MARK: Scroll sync

    private var syncPending = false

    /// Keeps a Markdown preview level with the editor: the block at the top of the editor is
    /// at the top of the preview, using the `data-sourcepos` line numbers in the HTML.
    func editorDidScroll() {
        guard !followingPreview, !syncPending, loadedShell != nil, editor?.textView.language.name == "Markdown" else { return }
        syncPending = true
        DispatchQueue.main.async { [weak self] in
            self?.syncPending = false
            self?.syncScroll()
        }
    }

    private func syncScroll() {
        guard let tv = editor?.textView, tv.language.name == "Markdown", let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let visible = tv.visibleRect
        let atEnd = visible.maxY >= tv.bounds.maxY - 1
        var point = visible.origin
        point.y = max(0, point.y - tv.textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: point, in: tc)
        let index = lm.characterIndexForGlyph(at: glyph)
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let ns = tv.string as NSString
        var line = 1
        var i = 0
        let end = min(index, ns.length)
        while i < end {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: i, length: end - i))
            if r.location == NSNotFound { break }
            line += 1
            i = r.location + 1
        }
        // How far into that line the top of the view is, for smooth scrolling through long paragraphs.
        let within = fragment.height > 0 ? min(max((point.y - fragment.minY) / fragment.height, 0), 1) : 0
        webView.evaluateJavaScript("window.quireScrollToLine && quireScrollToLine(\(Double(line) + Double(within)), \(atEnd))")
    }

    /// The reader scrolled the preview: bring the matching source line to the top of the editor.
    private func previewDidScroll(_ body: Any) {
        guard let info = body as? [String: Any], let line = (info["line"] as? NSNumber)?.doubleValue,
              let tv = editor?.textView, tv.language.name == "Markdown", let lm = tv.layoutManager,
              let window = webView.window else { return }
        // Only when the pointer is over the preview: page reloads also scroll it.
        let mouse = webView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard !followRequiresPointer || webView.bounds.contains(mouse) else { return }
        let ns = tv.string as NSString
        let lineIndex = LineIndex(tv.string)
        let whole = max(0, min(Int(line) - 1, lineIndex.lineCount - 1))
        let start = lineIndex.range(ofLine: whole).location
        var y: CGFloat
        if (info["atEnd"] as? Bool) == true {
            y = tv.bounds.height
        } else {
            let g = lm.glyphIndexForCharacter(at: min(start, max(ns.length - 1, 0)))
            let frag = ns.length == 0 ? .zero : lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            y = frag.minY + frag.height * CGFloat(line - Double(Int(line))) + tv.textContainerOrigin.y
        }
        followingPreview = true
        tv.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, tv.bounds.height - (tv.enclosingScrollView?.contentView.bounds.height ?? 0)))))
        tv.enclosingScrollView?.reflectScrolledClipView(tv.enclosingScrollView!.contentView)
        DispatchQueue.main.async { [weak self] in self?.followingPreview = false }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadedShell = pendingShell
        // Restore the scroll position now and again once diagrams and math have laid out.
        webView.evaluateJavaScript("""
            window.scrollTo(0, \(savedScroll));
            window.quireReady && window.quireReady.then(() => window.scrollTo(0, \(savedScroll)));
            """)
        if editor?.textView.language.name == "Markdown" {
            webView.callAsyncJavaScript("if (window.quireReady) await window.quireReady;", arguments: [:], in: nil, in: .page) { [weak self] _ in
                self?.syncScroll()
            }
        }
    }

    /// What the pane currently shows, as drawn by WebKit (for tests).
    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        webView.takeSnapshot(with: nil) { image, _ in done(image) }
    }

    /// Resolves once highlighting, math and diagrams on the current page have rendered (for tests).
    func whenRendered(_ done: @escaping (String?) -> Void) {
        webView.callAsyncJavaScript("""
            if (window.quireReady) await window.quireReady;
            return document.body.innerHTML;
            """, arguments: [:], in: nil, in: .page) { done(try? $0.get() as? String) }
    }

    /// Runs a script in the page and returns its result (for tests).
    func evaluate(_ script: String, _ done: @escaping (Any?) -> Void) {
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { done(try? $0.get()) }
    }

    /// Links open in the default browser instead of replacing the preview.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           url.fragment == nil || url.deletingFragment != tempFile {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    @objc private func openInBrowser(_ sender: Any?) {
        let url = tempFile.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).html")
        try? Data(renderHTML().utf8).write(to: url)
        NSWorkspace.shared.open(url)
    }
}

/// Receives the preview's scroll messages without the content controller retaining the pane.
private final class ScrollMessageRelay: NSObject, WKScriptMessageHandler {
    var onMessage: ((Any) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage?(message.body)
    }
}

private extension URL {
    var deletingFragment: URL {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.url ?? self
    }
}
