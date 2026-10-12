import AppKit
import WebKit
import QuireCore

/// Live HTML / Markdown preview that follows the editor as you type,
/// keeping its scroll position across refreshes.
final class PreviewWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    private static var open: [PreviewWindowController] = []
    private weak var editor: EditorViewController?
    private let webView: WKWebView
    private var pending: DispatchWorkItem?
    private var savedScroll: CGFloat = 0
    private let tempFile: URL

    static func show(for editor: EditorViewController) {
        if let existing = editor.preview { existing.showWindow(nil); existing.update(); return }
        let wc = PreviewWindowController(editor: editor)
        open.append(wc)
        editor.preview = wc
        wc.showWindow(nil)
        wc.update()
    }

    private init(editor: EditorViewController) {
        self.editor = editor
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        webView = WKWebView(frame: .zero, configuration: config)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Quire/Preview")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempFile = dir.appendingPathComponent("\(UUID().uuidString).html")

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.delegate = self
        w.contentView = webView
        webView.navigationDelegate = self
        w.setFrameAutosaveName("QuirePreview")
        if let editorWindow = editor.view.window, !w.setFrameUsingName("QuirePreview") {
            w.setFrameTopLeftPoint(NSPoint(x: editorWindow.frame.maxX + 8, y: editorWindow.frame.maxY))
        }
        updateTitle()

        let open = NSButton(title: "Open in Browser", target: self, action: #selector(openInBrowser(_:)))
        open.bezelStyle = .rounded
        open.controlSize = .small
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 130, height: 28))
        open.frame = NSRect(x: 0, y: 2, width: 122, height: 24)
        accessory.view.addSubview(open)
        accessory.layoutAttribute = .trailing
        w.addTitlebarAccessoryViewController(accessory)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        window?.title = "Preview — \(editor?.displayName ?? "")"
    }

    func scheduleUpdate() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.update() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Builds the page for the editor's current text.
    private func renderHTML() -> String {
        guard let editor else { return "" }
        let text = editor.textView.string
        let base = editor.doc?.fileURL?.deletingLastPathComponent()
        switch editor.textView.language.name {
        case "HTML":
            guard let base else { return text }
            // Resolve relative links against the document's folder.
            let tag = "<base href=\"\(Markdown.escape(base.absoluteString))\">"
            if let r = text.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                return text.replacingCharacters(in: r, with: text[r] + tag)
            }
            return tag + text
        case "Markdown":
            return Markdown.page(body: Markdown.html(text), title: editor.displayName, baseURL: base)
        default:
            return Markdown.page(body: "<pre><code>\(Markdown.escape(text))</code></pre>", title: editor.displayName, baseURL: base)
        }
    }

    func update() {
        guard editor != nil else { close(); return }
        updateTitle()
        let html = renderHTML()
        webView.evaluateJavaScript("window.scrollY") { [weak self] y, _ in
            guard let self else { return }
            if let y = y as? CGFloat { self.savedScroll = y }
            try? Data(html.utf8).write(to: self.tempFile)
            // Read access to "/" lets relative images and stylesheets load from the document's folder.
            self.webView.loadFileURL(self.tempFile, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.scrollTo(0, \(savedScroll))")
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

    func windowWillClose(_ notification: Notification) {
        try? FileManager.default.removeItem(at: tempFile)
        if editor?.preview === self { editor?.preview = nil }
        Self.open.removeAll { $0 === self }
    }
}

private extension URL {
    var deletingFragment: URL {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.url ?? self
    }
}
