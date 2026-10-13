import AppKit
import WebKit
import QuireCore

/// Pictures that stand in for Markdown in Live Preview: images, typeset math and diagrams
/// (Mermaid, D2, Graphviz). Rendering is asynchronous and cached; `onReady` fires when new pictures arrive
/// so the editor can lay them out.
final class MarkdownWidgets {
    enum Kind: Hashable {
        case image(URL, modified: Date?)
        case math(String, display: Bool)
        /// A diagram engine ("mermaid", "d2", "graphviz") and its source.
        case diagram(String, String)
    }

    struct Key: Hashable {
        var kind: Kind
        var dark: Bool
        var fontSize: CGFloat
    }

    private var images: [Key: NSImage] = [:]
    private var ids: [Key: Int] = [:]
    private var byID: [Int: NSImage] = [:]
    private var baselines: [Int: CGFloat] = [:]
    private var pending: Set<Key> = []
    private var failed: Set<Key> = []
    /// Called on the main thread when a picture finishes rendering.
    var onReady: (() -> Void)?

    /// The picture for `kind` if it's ready (with a stable id for drawing); otherwise starts
    /// rendering it and returns nil.
    func picture(_ kind: Kind, dark: Bool, fontSize: CGFloat) -> (id: Int, image: NSImage)? {
        let key = Key(kind: kind, dark: dark, fontSize: fontSize)
        if let image = images[key], let id = ids[key] { return (id, image) }
        guard !pending.contains(key), !failed.contains(key) else { return nil }
        pending.insert(key)
        let done: (NSImage?, CGFloat?) -> Void = { [weak self] image, baseline in
            guard let self else { return }
            self.pending.remove(key)
            guard let image, image.size.width > 0, image.size.height > 0 else { self.failed.insert(key); return }
            if self.images.count > 300 { self.images.removeAll(); self.byID.removeAll(); self.ids.removeAll() }
            let id = self.ids[key] ?? (self.ids.count + 1)
            self.ids[key] = id
            self.images[key] = image
            self.byID[id] = image
            if let baseline { self.baselines[id] = baseline / image.size.height }
            self.onReady?()
        }
        switch kind {
        case .image(let url, _): Self.loadImage(url) { done($0, nil) }
        case .math(let tex, let display): WidgetWebRenderer.shared.render(.init(kind: "math", source: tex, display: display, dark: dark, fontSize: fontSize), done)
        case .diagram(let engine, let source): WidgetWebRenderer.shared.render(.init(kind: engine, source: source, display: true, dark: dark, fontSize: fontSize), done)
        }
        return nil
    }

    func image(id: Int) -> NSImage? { byID[id] }

    /// Where the baseline falls in a math picture, as a fraction of its height from the top.
    func baseline(id: Int) -> CGFloat? { baselines[id] }

    /// Forgets failures (e.g. after an image file appears).
    func retryFailed() { failed.removeAll() }

    private static let session = URLSession(configuration: .ephemeral)

    private static func loadImage(_ url: URL, _ done: @escaping (NSImage?) -> Void) {
        if url.isFileURL {
            DispatchQueue.global(qos: .userInitiated).async {
                let image = NSImage(contentsOf: url)
                DispatchQueue.main.async { done(image) }
            }
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            session.dataTask(with: url) { data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { done(image) }
            }.resume()
        } else {
            done(nil)
        }
    }
}

/// Renders math (KaTeX) and diagrams (Mermaid, D2, Graphviz) with the preview's libraries in an off-screen
/// web view, one job at a time, and snapshots the result with a transparent background.
final class WidgetWebRenderer: NSObject, WKNavigationDelegate {
    static let shared = WidgetWebRenderer()

    struct Job {
        var kind: String
        var source: String
        var display: Bool
        var dark: Bool
        var fontSize: CGFloat
    }

    private var queue: [(Job, (NSImage?, CGFloat?) -> Void)] = []
    private var busy = false
    private var loaded = false
    private var webView: WKWebView?
    private var window: NSWindow?

    private func setUp() -> WKWebView? {
        if let webView { return webView }
        guard let assets = PreviewPane.assets else { return nil }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 1400))
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        let win = NSWindow(contentRect: NSRect(x: -40000, y: -40000, width: 1400, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = web
        win.orderFront(nil)
        window = win
        webView = web
        func url(_ p: String) -> String { assets.appendingPathComponent(p).absoluteString }
        let page = """
            <!doctype html><html><head><meta charset="utf-8">
            <link rel="stylesheet" href="\(url("katex/katex.min.css"))">
            <style>
            html, body { margin: 0; padding: 0; background: transparent; }
            #w { display: inline-block; padding: 2px 3px; font-family: -apple-system, sans-serif; }
            #w .katex-display { margin: 0; }
            #w svg { display: block; }
            </style>
            <script src="\(url("quire-preview.js"))"></script>
            </head><body><div id="w"></div>
            <script>
            window.quireRenderWidget = async function (kind, source, display, dark, fontSize, color) {
                const w = document.getElementById("w");
                w.style.fontSize = fontSize + "px";
                w.style.color = color;
                if (kind === "math") {
                    await quireLoad("katex/katex.min.js");
                    w.innerHTML = katex.renderToString(source, { displayMode: display, throwOnError: false });
                } else {
                    w.innerHTML = await quireRenderDiagram(kind, source, dark ? "dark" : "light", "quire-widget-" + Date.now());
                    // Draw at the diagram's own size: a "100%" width in this shrink-to-fit box
                    // would fall back to 300px and squash wide diagrams.
                    const svg = w.querySelector("svg");
                    if (svg) {
                        const box = svg.viewBox.baseVal;
                        if (box && box.width > 0) svg.setAttribute("width", Math.min(box.width, 900));
                        svg.style.maxWidth = "900px";
                        svg.removeAttribute("height");
                    }
                }
                // A zero-size inline-block's bottom edge sits on the baseline.
                const probe = document.createElement("span");
                probe.style.cssText = "display:inline-block;width:0;height:0";
                w.appendChild(probe);
                await document.fonts.ready;
                // requestAnimationFrame never fires in an off-screen window; give layout a moment.
                await new Promise(r => setTimeout(r, 30));
                const r = w.getBoundingClientRect();
                const baseline = probe.getBoundingClientRect().bottom - r.top;
                probe.remove();
                return { width: Math.ceil(r.width), height: Math.ceil(r.height), baseline: baseline };
            };
            </script></body></html>
            """
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Quire/Preview/widgets.html")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(page.utf8).write(to: file)
        web.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        return web
    }

    func render(_ job: Job, _ done: @escaping (NSImage?) -> Void) {
        render(job) { image, _ in done(image) }
    }

    /// `done` also gets the baseline's distance from the picture's top, in points.
    func render(_ job: Job, _ done: @escaping (NSImage?, CGFloat?) -> Void) {
        queue.append((job, done))
        next()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty, let web = setUp(), loaded else { return }
        busy = true
        let (job, rawDone) = queue.removeFirst()
        // Each job finishes once: with its picture, or empty after 10 seconds.
        var finished = false
        var baseline: CGFloat?
        let done: (NSImage?) -> Void = { [weak self] image in
            guard !finished else { return }
            finished = true
            self?.busy = false
            rawDone(image, baseline)
            self?.next()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { done(nil) }
        web.appearance = NSAppearance(named: job.dark ? .darkAqua : .aqua)
        let color = job.dark ? "#d8d8da" : "#1d1d1f"
        web.callAsyncJavaScript("return await quireRenderWidget(kind, source, display, dark, fontSize, color)",
                                arguments: ["kind": job.kind, "source": job.source, "display": job.display, "dark": job.dark,
                                            "fontSize": job.fontSize, "color": color],
                                in: nil, in: .page) { result in
            guard case .success(let value) = result, let size = value as? [String: Any],
                  let w = (size["width"] as? NSNumber)?.doubleValue, let h = (size["height"] as? NSNumber)?.doubleValue, w > 0, h > 0 else {
                done(nil)
                return
            }
            baseline = (size["baseline"] as? NSNumber).map { CGFloat($0.doubleValue) }
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: min(w, 1400), height: min(h, 1400))
            // An off-screen window never gets screen updates to wait for.
            config.afterScreenUpdates = false
            web.takeSnapshot(with: config) { image, _ in done(image) }
        }
    }
}
