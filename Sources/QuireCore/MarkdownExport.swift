import Foundation

/// Options for exporting Markdown as HTML or PDF.
public struct MarkdownExportOptions: Equatable {
    public enum Images: String, CaseIterable {
        /// Inline local images as `data:` URIs, so the page is one file.
        case embed
        /// Leave `src` attributes as written.
        case link
        /// Copy local images into a `<name>_files` folder next to the page.
        case copy
    }
    public var images: Images = .embed
    /// Run raw HTML through GitHub's tag filter.
    public var sanitizeHTML = false
    /// A linked table of contents (levels 1–3) at the top.
    public var tableOfContents = false
    /// PDF: a first page with the title, author and date from front matter.
    public var titlePage = false
    /// PDF: page numbers in the footer.
    public var pageNumbers = true
    /// PDF and print: a link's address after its text, for readers on paper.
    public var linkAddresses = false
    /// Curly quotes, dashes and ellipses.
    public var smartPunctuation = false

    public enum Theme: String, CaseIterable {
        case light, dark
        /// Light or dark following the reader's system setting.
        case auto
    }
    /// HTML: the colour scheme of the page.
    public var theme: Theme = .light

    public init() {}
}

/// The pieces of a self-contained export page. The rendering itself (highlighting, math,
/// diagrams) happens in WebKit; this assembles and post-processes the result.
public enum MarkdownExport {

    /// The document's title: front matter `title`, else the first heading, else `fallback`.
    public static func title(of doc: MarkdownDocument, fallback: String) -> String {
        if let t = doc.frontMatter.first(where: { $0.key.lowercased() == "title" })?.value, !t.isEmpty { return t }
        return doc.headings.first?.text ?? fallback
    }

    public static func frontMatterValue(_ doc: MarkdownDocument, _ key: String) -> String? {
        doc.frontMatter.first { $0.key.lowercased() == key }?.value
    }

    /// The HTML body to render for export: the document without its front matter table,
    /// optionally preceded by a title page and a table of contents.
    public static func body(_ doc: MarkdownDocument, title: String, options: MarkdownExportOptions) -> String {
        var out = ""
        if options.titlePage {
            out += "<section class=\"title-page\"><h1 class=\"title\">\(Markdown.escape(title))</h1>"
            for key in ["subtitle", "author", "date"] {
                if let v = frontMatterValue(doc, key), !v.isEmpty { out += "<p class=\"\(key)\">\(Markdown.escape(v))</p>" }
            }
            out += "</section>\n"
        }
        if options.tableOfContents { out += tableOfContents(doc.headings) }
        out += doc.html(includeFrontMatter: false)
        return out
    }

    /// A nested list of links to headings of levels 1–3.
    public static func tableOfContents(_ headings: [MarkdownHeading], maxLevel: Int = 3) -> String {
        let items = headings.filter { $0.level <= maxLevel }
        guard !items.isEmpty else { return "" }
        let base = items.map(\.level).min()!
        var out = "<nav class=\"toc\"><p class=\"toc-title\">Contents</p>\n<ul>\n"
        var depth = 0
        for (i, h) in items.enumerated() {
            let level = h.level - base
            if i > 0 {
                if level > depth {
                    for _ in depth..<level { out += "\n<ul>\n" }
                } else {
                    out += "</li>\n"
                    for _ in level..<depth { out += "</ul>\n</li>\n" }
                }
            }
            depth = max(level, 0)
            out += "<li><a href=\"#\(Markdown.escape(h.id))\">\(Markdown.escape(h.text))</a>"
        }
        out += "</li>\n"
        for _ in 0..<depth { out += "</ul>\n</li>\n" }
        out += "</ul>\n</nav>\n"
        return out
    }

    // MARK: Stylesheets

    /// Keeps the contents of `@media (prefers-color-scheme: dark) { … }` blocks, unconditionally,
    /// so a page stays dark. They come after the light rules, so they win.
    public static func darkOnly(_ css: String) -> String {
        rewriteDarkBlocks(css, keepContents: true).replacingOccurrences(of: "color-scheme: light dark", with: "color-scheme: dark")
    }

    /// Wraps a stylesheet so it applies only in one colour scheme.
    public static func onlyIn(_ scheme: String, _ css: String) -> String {
        "@media (prefers-color-scheme: \(scheme)) {\n\(css)\n}"
    }

    private static func rewriteDarkBlocks(_ css: String, keepContents: Bool) -> String {
        var out = ""
        var rest = css[...]
        while let r = rest.range(of: "@media (prefers-color-scheme: dark)") {
            out += rest[..<r.lowerBound]
            guard let open = rest[r.upperBound...].firstIndex(of: "{") else { rest = rest[r.upperBound...]; break }
            var depth = 0
            var i = open
            while i < rest.endIndex {
                if rest[i] == "{" { depth += 1 } else if rest[i] == "}" { depth -= 1; if depth == 0 { break } }
                i = rest.index(after: i)
            }
            if keepContents, i < rest.endIndex { out += rest[rest.index(after: open)..<i] }
            rest = i < rest.endIndex ? rest[rest.index(after: i)...] : rest[rest.endIndex...]
        }
        out += rest
        return out
    }

    /// Removes `@media (prefers-color-scheme: dark) { … }` blocks so a page stays light.
    public static func lightOnly(_ css: String) -> String {
        var out = ""
        var rest = css[...]
        while let r = rest.range(of: "@media (prefers-color-scheme: dark)") {
            out += rest[..<r.lowerBound]
            guard let open = rest[r.upperBound...].firstIndex(of: "{") else { rest = rest[r.upperBound...]; break }
            var depth = 0
            var i = open
            while i < rest.endIndex {
                if rest[i] == "{" { depth += 1 } else if rest[i] == "}" { depth -= 1; if depth == 0 { break } }
                i = rest.index(after: i)
            }
            rest = i < rest.endIndex ? rest[rest.index(after: i)...] : rest[rest.endIndex...]
        }
        out += rest
        return out.replacingOccurrences(of: "color-scheme: light dark", with: "color-scheme: light")
    }

    struct FontFace { var family: String; var weight: String; var style: String }

    static let fontFaceRule = try! NSRegularExpression(pattern: #"@font-face\s*\{[^}]*\}"#)

    /// KaTeX's stylesheet with the fonts the page actually used embedded as WOFF2 `data:`
    /// URIs and every other `@font-face` rule removed. `used` holds (family, weight, style)
    /// of the faces WebKit loaded; `fonts` is the folder of `.woff2` files.
    public static func katexCSS(_ css: String, fonts: URL, used: [(family: String, weight: String, style: String)]) -> String {
        let ns = css as NSString
        var out = ""
        var last = 0
        func norm(_ w: String) -> String { w == "normal" ? "400" : w == "bold" ? "700" : w }
        let usedSet = Set(used.map { "\($0.family)|\(norm($0.weight))|\($0.style)" })
        for m in fontFaceRule.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = NSMaxRange(m.range)
            let rule = ns.substring(with: m.range)
            func prop(_ name: String) -> String? {
                guard let r = rule.range(of: "\(name):\\s*([^;}]+)", options: .regularExpression) else { return nil }
                return String(rule[r].dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            guard let family = prop("font-family")?.replacingOccurrences(of: "\"", with: ""),
                  usedSet.contains("\(family)|\(norm(prop("font-weight") ?? "400"))|\(prop("font-style") ?? "normal")"),
                  let file = rule.range(of: #"url\(fonts/[^)]+\.woff2\)"#, options: .regularExpression).map({ String(rule[$0].dropFirst(4).dropLast()) }),
                  let data = try? Data(contentsOf: fonts.deletingLastPathComponent().appendingPathComponent(file)) else { continue }
            out += "@font-face{font-family:\(family);font-style:\(prop("font-style") ?? "normal");font-weight:\(prop("font-weight") ?? "400");"
                + "src:url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")}"
        }
        out += ns.substring(from: last)
        return out
    }

    /// CSS for exported pages: print layout, title page and contents.
    public static let exportCSS = """
        nav.toc { margin: 0 0 2em; padding: .8em 1.2em; border: 1px solid var(--border); border-radius: 8px; }
        nav.toc .toc-title { margin: 0 0 .4em; font-weight: 600; }
        nav.toc ul { margin: 0; padding-left: 1.2em; list-style: none; } nav.toc > ul { padding-left: 0; }
        section.title-page { text-align: center; padding: 25vh 0 0; }
        section.title-page h1 { border: 0; font-size: 2.4em; margin: 0 0 .5em; }
        section.title-page p { color: var(--muted); margin: .3em 0; font-size: 1.1em; }
        @media print {
            body { max-width: none; margin: 0; padding: 0; font-size: 11pt; }
            * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
            pre, table, figure, img, .math-display, blockquote, .markdown-alert, tr { break-inside: avoid; }
            h1, h2, h3, h4, h5, h6 { break-after: avoid; }
            .keep-with-next { break-inside: avoid; }
            pre { white-space: pre-wrap; overflow-wrap: anywhere; overflow: visible; }
            pre .copy, pre[data-lang]::before { display: none; }
            section.title-page { break-after: page; padding-top: 30vh; }
            nav.toc { break-after: page; border: 0; padding: 0; }
            a { color: inherit; }
        }
        """

    /// WebKit ignores `break-after: avoid` when printing, so before printing, each heading is
    /// wrapped with the block after it (when that block is short) in a `.keep-with-next` div.
    public static let keepHeadingsWithNextScript = """
        for (const h of [...document.body.querySelectorAll("h1, h2, h3, h4, h5, h6")]) {
            const next = h.nextElementSibling;
            if (!next || /^H[1-6]$/.test(next.tagName) || next.offsetHeight > 400 || h.parentElement.classList.contains("keep-with-next")) continue;
            const wrap = document.createElement("div");
            wrap.className = "keep-with-next";
            h.before(wrap);
            wrap.append(h, next);
        }
        """

    /// Printed pages: each web or mail link followed by its address.
    public static let linkAddressCSS = """
        @media print {
            a[href^="http"]::after, a[href^="mailto:"]::after { content: " (" attr(href) ")"; color: var(--muted); font-size: .85em; overflow-wrap: anywhere; }
            a.footnote-backref::after, sup a::after { content: none; }
        }
        """

    /// For pages offering both schemes: diagrams are rendered twice and the matching one shown.
    public static let schemeSwitchCSS = """
        .only-dark { display: none; }
        @media (prefers-color-scheme: dark) { .only-dark { display: block; } .only-light { display: none; } }
        """

    static let diagramFigure = try! NSRegularExpression(pattern: #"<figure class="diagram[^"]*"[^>]*>[\s\S]*?</figure>"#)

    /// Puts the dark rendering of each diagram after its light one, each marked to show only
    /// in its colour scheme. The two bodies must come from the same document.
    public static func mergeDiagrams(light: String, dark: String) -> String {
        let darkNS = dark as NSString
        let darkFigures = diagramFigure.matches(in: dark, range: NSRange(location: 0, length: darkNS.length)).map { darkNS.substring(with: $0.range) }
        let ns = light as NSString
        var out = ""
        var last = 0
        for (i, m) in diagramFigure.matches(in: light, range: NSRange(location: 0, length: ns.length)).enumerated() {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let fig = ns.substring(with: m.range)
            out += fig.replacingOccurrences(of: "<figure class=\"diagram", with: "<figure class=\"only-light diagram")
            if i < darkFigures.count {
                out += darkFigures[i].replacingOccurrences(of: "<figure class=\"diagram", with: "<figure class=\"only-dark diagram")
            }
            last = NSMaxRange(m.range)
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: Pages

    /// A complete self-contained page around an already rendered body.
    public static func page(title: String, body: String, stylesheets: [String], lang: String = "en", colorScheme: String = "light") -> String {
        """
        <!doctype html>
        <html lang="\(lang)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="\(colorScheme)">
        <meta name="generator" content="Quire">
        <title>\(Markdown.escape(title))</title>
        <style>
        \(stylesheets.joined(separator: "\n"))
        </style>
        </head><body>
        \(body)
        </body></html>

        """
    }

    // MARK: Images

    static let imgSrc = try! NSRegularExpression(pattern: #"(<img\b[^>]*?\bsrc=")([^"]*)(")"#, options: .caseInsensitive)

    static let mimeTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                            "svg": "image/svg+xml", "webp": "image/webp", "heic": "image/heic", "avif": "image/avif",
                            "bmp": "image/bmp", "ico": "image/x-icon", "tif": "image/tiff", "tiff": "image/tiff"]

    /// Rewrites local `<img src>` URLs (relative to `base`) for the export: as `data:` URIs,
    /// or copied into `filesDir` (whose name the page refers to). Remote and missing images are left alone.
    public static func processImages(_ html: String, base: URL?, mode: MarkdownExportOptions.Images, filesDir: URL? = nil) -> String {
        guard mode != .link else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        var copied: [String: String] = [:]
        for m in imgSrc.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range(at: 2).location - last))
            last = NSMaxRange(m.range(at: 2))
            let src = ns.substring(with: m.range(at: 2))
            let raw = src.replacingOccurrences(of: "&amp;", with: "&")
            guard let file = localFile(raw, base: base), let data = try? Data(contentsOf: file) else { out += src; continue }
            switch mode {
            case .embed:
                let mime = mimeTypes[file.pathExtension.lowercased()] ?? "application/octet-stream"
                out += "data:\(mime);base64,\(data.base64EncodedString())"
            case .copy:
                guard let dir = filesDir else { out += src; continue }
                if let done = copied[file.path] { out += done; continue }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var name = file.lastPathComponent
                var n = 1
                while copied.values.contains(dir.lastPathComponent + "/" + name) {
                    n += 1
                    name = file.deletingPathExtension().lastPathComponent + "-\(n)." + file.pathExtension
                }
                let dest = dir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try? data.write(to: dest)
                let rel = dir.lastPathComponent + "/" + name
                copied[file.path] = rel
                out += Markdown.escape(rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel)
            case .link:
                out += src
            }
        }
        out += ns.substring(from: last)
        return out
    }

    /// The local file an image `src` points to, or nil for remote, data and missing images.
    static func localFile(_ src: String, base: URL?) -> URL? {
        if src.hasPrefix("data:") || src.hasPrefix("http:") || src.hasPrefix("https:") || src.hasPrefix("//") { return nil }
        let url: URL?
        if src.hasPrefix("file:") { url = URL(string: src) }
        else if src.hasPrefix("/") { url = URL(fileURLWithPath: src.removingPercentEncoding ?? src) }
        else if let base {
            let dir = base.isFileURL ? URL(fileURLWithPath: base.path, isDirectory: true) : base
            url = URL(string: src, relativeTo: dir)?.absoluteURL ?? dir.appendingPathComponent(src.removingPercentEncoding ?? src)
        }
        else { url = nil }
        guard let u = url, u.isFileURL, FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }
}
