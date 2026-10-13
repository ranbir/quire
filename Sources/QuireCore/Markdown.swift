import Foundation

/// Markdown → HTML. Parsing and rendering live in `MarkdownDocument`; this holds the
/// one-call entry point, HTML escaping and the preview page template.
public enum Markdown {

    public static func html(_ source: String, options: MarkdownOptions = .default) -> String {
        MarkdownDocument(TextCodec.normalizeLineEndings(source), options: options).html()
    }

    // MARK: Diagrams

    /// The diagram engine for a fenced code block's info string ("mermaid", "d2" or
    /// "graphviz"), or nil when the block is ordinary code.
    public static func diagramEngine(info: String) -> String? {
        switch info.split(separator: " ").first?.lowercased() ?? "" {
        case "mermaid": return "mermaid"
        case "d2": return "d2"
        case "dot", "graphviz": return "graphviz"
        default: return nil
        }
    }

    // MARK: Escaping

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// The page's base stylesheet: typography, colours (light and dark), code, tables.
    public static let pageCSS = """
        :root { color-scheme: light dark; --fg:#1d1d1f; --bg:#fff; --muted:#6e6e73; --code:#f3f3f5; --border:#d8d8dc; --link:#0b65d8; }
        @media (prefers-color-scheme: dark) { :root { --fg:#e6e6e8; --bg:#1e1f22; --muted:#9a9aa0; --code:#2a2b30; --border:#3a3b40; --link:#6aa8ff; } }
        body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg); background: var(--bg);
               max-width: 820px; margin: 0 auto; padding: 28px 32px 80px; }
        h1, h2 { border-bottom: 1px solid var(--border); padding-bottom: .25em; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 1.4em 0 .6em; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: 0.88em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: .15em .35em; border-radius: 4px; }
        pre { background: var(--code); padding: 14px 16px; border-radius: 8px; overflow: auto; line-height: 1.45; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding: 0 1em; color: var(--muted); border-left: 4px solid var(--border); }
        table { border-collapse: collapse; margin: 1em 0; } th, td { border: 1px solid var(--border); padding: 6px 12px; }
        th { background: var(--code); } img { max-width: 100%; } hr { border: 0; border-top: 1px solid var(--border); margin: 2em 0; }
        li > input[type=checkbox] { margin-right: .4em; }
        """

    /// Wraps rendered HTML in a full page with a readable stylesheet. `assets` is the folder
    /// holding quire-preview.js and its libraries (highlighting, math, diagrams).
    public static func page(body: String, title: String, baseURL: URL? = nil, assets: URL? = nil, extraCSS: String = "") -> String {
        let base = baseURL.map { "<base href=\"\(escape($0.absoluteString))\">" } ?? ""
        let scripts = assets.map { dir -> String in
            func url(_ path: String) -> String { escape(dir.appendingPathComponent(path).absoluteString) }
            return """
            <link rel="stylesheet" href="\(url("hljs/github.min.css"))" media="(prefers-color-scheme: light)">
            <link rel="stylesheet" href="\(url("hljs/github-dark.min.css"))" media="(prefers-color-scheme: dark)">
            <link rel="stylesheet" href="\(url("katex/katex.min.css"))">
            <link rel="stylesheet" href="\(url("quire-preview.css"))">
            <script defer src="\(url("hljs/highlight.min.js"))"></script>
            <script defer src="\(url("hljs/extra-languages.min.js"))"></script>
            <script defer src="\(url("quire-preview.js"))"></script>
            """
        } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8">\(base)<title>\(escape(title))</title>
        <meta name="color-scheme" content="light dark">
        <style>
        \(pageCSS)
        \(extraCSS)
        </style>
        \(scripts)</head><body>
        \(body)
        </body></html>
        """
    }
}
