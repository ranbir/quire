# Plan: full Markdown, live formatting and HTML/PDF export

> **Status (October 2026): implemented** on the `markdown-engine` branch, all six stages. Where the work differs from this plan:
> - Math in the editor is rendered with the bundled KaTeX (as pictures) instead of SwiftMath: no extra size, same look as the preview.
> - CommonMark 0.31.2: 641 of 652 examples (98.3%). The 11 differences are rule changes after 0.29, the version GitHub's parser follows; the GFM spec passes 670/670.
> - Copy as Rich Text is `⌥⌘C` (`⌥⇧⌘C` was taken by Copy Path).
> - The app grew from 8.3 MB to 10 MB.
>
> How to test it: [testing-markdown.md](testing-markdown.md).

Three goals:

1. **Full Markdown.** Pass the CommonMark and GitHub Flavored Markdown spec test suites, not a hand-picked subset, and add the extensions people expect (math, Mermaid, footnotes, front matter, alerts).
2. **Formatting while you type.** Markdown documents look formatted in the editor itself. Headings are large, bold is bold, and the `**` and `#` markers fade away except where the cursor is, as in Obsidian's Live Preview.
3. **Export.** Save a document as a self-contained HTML file or a paginated PDF that looks like the preview, with diagrams and math rendered, and that works on someone else's machine.

The file on disk stays plain Markdown throughout. Formatting is applied only on screen, so undo, Git diffs, search, AppleScript, Text Filters and the AI transform keep working on the real source.

---

## 1. Where things stand today

| Piece | Today | Problem |
|---|---|---|
| Parser and renderer | `Sources/QuireCore/Markdown.swift`: about 500 lines of line-by-line regexes and an inline stash/replace pass | Covers the common cases only. It can't track source positions, so the editor can't use it, and it will keep drifting from the spec on edge cases (nested lists, lazy continuation, link reference precedence, emphasis rules) |
| Editor colouring | `SyntaxHighlighter` (`TextViewSupport.swift:350`) runs the generic `Tokenizer` on a background queue and applies **temporary attributes** (colour only) | Temporary attributes can't change fonts or sizes, so headings can't get bigger and bold can't be bold |
| Glyph hiding | `FoldManager` is the `NSLayoutManagerDelegate` and hides folded text in `shouldGenerateGlyphs` (`TextViewSupport.swift:162`) | This is the mechanism needed to hide Markdown markers. It already works, which is the main reason to stay on TextKit 1 |
| Preview | `PreviewPane` renders `Markdown.html` into a `WKWebView` and swaps the body in place through `quireUpdate(html)` | Fine. It just needs the new renderer |
| Export | Open in Browser writes a temporary page that loads assets from inside Quire.app | Doesn't work once the file leaves the Mac. There's no Save as HTML and no PDF export |
| Print | `Document.printOperation` prints the source text | For Markdown, people will expect it to print the formatted page |

---

## 2. Full Markdown support

### 2.1 Parser: adopt cmark-gfm

Use GitHub's **cmark-gfm**, the C reference implementation that github.com uses, through Apple's SwiftPM package `swift-cmark` (`gfm` branch, BSD-2 licence).

Why cmark-gfm rather than a better hand-written parser:
- It passes 100% of the CommonMark spec, plus GFM tables, task lists, strikethrough, autolinks and footnotes.
- **Source positions** (`line:column` for every block and inline node) are what live formatting needs (section 3).
- It's fast: a few milliseconds for a typical document and well under 50 ms for a book-length file. That's fast enough to re-parse on every keystroke batch.
- It builds as a plain SwiftPM C target, so the universal arm64/x86_64 build in `build.sh` keeps working unchanged.

Rejected alternatives: markdown-it in the web view (the editor needs a Swift-side syntax tree), and `swift-markdown` on its own (a fine Swift API over the same cmark, but its HTML output is less mature, and we need the raw cmark API for syntax extensions anyway). `swift-markdown` is still worth adopting later as the Swift-facing syntax tree if the C API gets awkward.

Package change:

```swift
dependencies: [.package(url: "https://github.com/apple/swift-cmark", branch: "gfm")],
targets: [
    .target(name: "QuireCore", dependencies: [.product(name: "cmark-gfm", package: "swift-cmark"),
                                              .product(name: "cmark-gfm-extensions", package: "swift-cmark")]),
    ...
]
```

Pin to a tag or revision before release.

### 2.2 New QuireCore API

Replace `Markdown.html(_:)` with a small module, keeping the old entry point as a thin wrapper so `PreviewPane` and the tests don't change shape:

```swift
public struct MarkdownDocument {
    public init(_ source: String, options: MarkdownOptions = .default)
    public var root: MDNode { get }                 // Swift wrapper over the cmark syntax tree
    public func html(sourcePositions: Bool) -> String
    public var frontMatter: [String: String]? { get }
    public var headings: [(level: Int, text: String, range: NSRange)] { get }   // for Symbols, folding, export table of contents
}

public struct MDNode {
    public var kind: Kind          // heading(level), emphasis, strong, code, link(url), image, list, item, table, mathInline, …
    public var range: NSRange      // UTF-16 range in the source, ready for NSTextView
    public var markers: [NSRange]  // delimiter ranges: "**", "# ", "`", "[", "](url)", "> ", list bullets
    public var children: [MDNode]
}
```

`range` and `markers` are what the editor needs. Two details matter here:
- **Converting positions.** cmark reports 1-based lines and UTF-8 byte columns, while `NSTextView` uses UTF-16 offsets. Build a line-start table once per parse and convert per line. Unit-test this with emoji, CJK, combining marks and tabs.
- **Finding markers.** cmark's inline source positions are known to be approximate in places (after soft line breaks, around entities). Don't trust them for markers. Take the node's outer range from cmark and find the delimiter characters by scanning the source at each end of that range. For example, emphasis markers are the run of `*` or `_` at the start and end.

### 2.3 Extensions beyond GFM

| Extension | Syntax | How |
|---|---|---|
| Math, inline | `$…$`, `\(…\)` | A cmark-gfm **inline syntax extension** in C, about 200 lines modelled on the bundled `strikethrough.c`. It produces a `math` node whose content is not parsed for emphasis, so `$a_1 * b_2$` survives intact. Keep today's rules: no space just inside the `$`, and no digit right after the closing `$`, so "$5 and $10" stays text |
| Math, display | `$$…$$` on their own lines, and ```` ```math ```` | A pre-pass rewrites `$$` lines into ```` ```math ```` fences. It changes only those delimiter lines, so line numbers and columns elsewhere are untouched. The renderer turns `math` code blocks into `<div class="math math-display">` |
| Mermaid | ```` ```mermaid ```` | Tree rewrite: the code block becomes `<pre class="mermaid">`. The existing `quire-preview.js` already handles it |
| Front matter | `---` YAML at the top of the file | Blank out those lines before parsing, which keeps line numbers. Expose the fields as `frontMatter` and use `title` for the export title. Show it as a muted metadata box in the preview |
| Footnotes | `[^1]` | cmark-gfm `CMARK_OPT_FOOTNOTES` |
| GitHub alerts | `> [!NOTE]`, `[!TIP]`, `[!WARNING]`… | Tree rewrite on block quotes whose first line matches. Rendered as styled call-outs |
| Heading anchors | automatic | Post-pass on cmark's HTML adds `id` to `<hN>` using GitHub's slug rules (lower case, spaces become `-`, `-1`/`-2` suffixes for duplicates). Makes `[link](#heading)` work in the preview and in exports |
| Tables, task lists, strikethrough, autolinks | GFM | Built-in cmark-gfm extensions |
| Raw HTML | as written | `CMARK_OPT_UNSAFE` for the preview and export of your own files. Add a **Sanitize HTML** export option that applies the GFM `tagfilter` extension instead |
| Smart punctuation | optional | `CMARK_OPT_SMART`, off by default and offered as a preference |

Deliberately out of scope for now: wiki links (`[[…]]`), definition lists, emoji shortcodes, citations and MDX components. Each is cheap to add later as another syntax extension or tree rewrite.

### 2.4 Proving it's "full Markdown"

- Vendor `spec.txt` from CommonMark 0.31.2 and GFM 0.29-gfm into `Tests/QuireCoreTests/Spec/` and add a test that runs every example. The target is 100% for both, since we're using the reference implementation. Any failures come from our own extensions and must be justified one by one.
- **Run it against the current renderer first** to get a baseline pass rate. That number goes in the release notes ("CommonMark: 61% → 100%", or whatever it turns out to be). It's also a good line for the LinkedIn post.
- Golden tests for each extension (math edge cases, Mermaid, alerts, front matter, footnotes) and for position conversion.
- Keep `docs/preview-sample.md` up to date as the end-to-end sample.

### 2.5 Scroll sync (cheap once positions exist)

Render with `CMARK_OPT_SOURCEPOS` so every block carries `data-sourcepos="12:1-18:3"`. `quire-preview.js` can then scroll the preview to the block for the editor's top visible line and the other way round. It's a small change and a big improvement in how the preview feels.

---

## 3. Formatting while you type

### 3.1 Model

There are three common designs. Pick the Obsidian one.

| Model | Example | Verdict |
|---|---|---|
| Styled source: markers stay visible but muted | iA Writer, Bear (partly) | Low risk, and the first deliverable here (stage A) |
| **Live preview: markers hidden except near the cursor, rich widgets elsewhere** | Obsidian, Zettlr | **The target.** Stays honest to the file, matches what Quire users expect, and fits TextKit 1 |
| Full WYSIWYG: the document is a rendered tree and markers are never shown | Typora | Turns the text into a projection of a parse tree, which breaks clean round-trips, Git-friendly editing and every text-level feature Quire already has. Not worth it |

The mode is a per-document setting in **View ▸ Markdown ▸ Source / Styled / Live Preview**, with a status-bar toggle next to the eye icon. Live Preview is the default for `.md`; all other languages are unaffected.

### 3.2 Architecture (TextKit 1, building on what exists)

Stay on TextKit 1 (`NSLayoutManager`). TextKit 2's paragraph substitution is attractive, but moving folding, the line-number ruler, invisibles and fold capsules over to it would be a rewrite with known TextKit 2 bugs on large documents. If needed, revisit after this ships.

New components in `Sources/Quire/`:

1. **`MarkdownStyler`** replaces `SyntaxHighlighter` for Markdown documents.
   - Parses on the existing `quire.highlight` background queue (cmark is fast enough to re-parse the whole document), then applies styles on the main thread for the edited range plus the visible range first, and the rest in idle-time chunks.
   - Applies **real attributes** on the text storage (font, size, weight, paragraph spacing, indents, and colour for markers and links), because temporary attributes can't change fonts. Attribute edits are wrapped in `beginEditing`/`endEditing` directly on `NSTextStorage`. They don't go through `shouldChangeText`, so they don't touch the undo stack or the document's edited state. Add a self-test asserting that styling a file leaves the document clean and the undo stack empty.
   - Keeps a generation counter, like `SyntaxHighlighter`, so a slow parse never overwrites newer text.
   - Above about 2 MB, falls back to Styled mode, and above the existing 4 MB `maxLength` to Source.

2. **`MarkupHider`**, a glyph policy.
   - The layout manager has one delegate, `FoldManager`. Extend `FoldManager.shouldGenerateGlyphs` to consult a second, injected set of hidden ranges from `MarkupHider`, rather than adding a competing delegate. A character is hidden if it's folded **or** it's a marker outside the active region.
   - The **active region** is every block (paragraph, list item, heading, table, fence) that intersects the selection. Its markers are shown in a muted colour so you can edit them. Everything else hides them. When the selection changes, invalidate glyphs only for the old and new active blocks.
   - Hidden link URLs: `[text](https://…)` shows only `text`, styled as a link. ⌘-click opens it, and a plain click puts the cursor there and reveals the markup.

3. **Widgets**, for things that aren't styled text. The source characters stay in the storage, their glyphs are hidden, and the layout manager draws in their place, the same way fold capsules are drawn today (`InvisiblesLayoutManager.drawGlyphs`, `capsuleRect`). Extra vertical space comes from `layoutManager(_:shouldSetLineFragmentRect:…)`.
   - Checkboxes for `- [ ]`: drawn checkbox; clicking toggles the source character as a normal undoable edit.
   - Horizontal rules: a drawn line.
   - Bullets: `-`, `*`, `+` drawn as `•`, indentation as hanging indents through paragraph style.
   - Images: a thumbnail under the `![…](…)` line, loaded asynchronously and cached by path and modification date. Relative paths resolve against the document's folder, as in the preview.
   - Math: rendered to an image. Use **SwiftMath** (MIT, a native LaTeX renderer) for speed, with the KaTeX snapshot path below as a fallback for unsupported commands.
   - Mermaid: rendered in a shared off-screen `WKWebView` running the bundled `mermaid.min.js`, snapshotted to an image and cached by source and theme. While rendering, it shows the source; on errors, it shows the source with the error.
   - Tables: **not** a grid widget in this round. Instead: monospaced alignment, muted pipes, and **Tab/Return auto-format the table** (re-pad the columns), as Obsidian's Advanced Tables does. Cell-grid editing is a later project.

   Any widget turns back into its source when the cursor enters its block.

### 3.3 Editing behaviour for Markdown (all modes)

In `EditorTextView`, active only when the language is Markdown:
- **Return** continues lists (`-`, `1.` incrementing, `- [ ]`) and block quotes. Return on an empty item ends the list.
- **Tab / ⇧Tab** on a list item indents or outdents it, and renumbers ordered lists.
- **Format shortcuts:** bold, italic, inline code, link, strikethrough, heading level 1–6. These toggle when the selection is already formatted.
  - **Decision needed:** `⌘B` is currently Balance Brackets and `⌘K` is AI Transform. Suggestion: in Markdown documents, `⌘B` = bold and `⌘I` = italic (what every writer expects), with Balance moved to `⌃⌘B` there. Keep `⌘K` for AI and use `⇧⌘K` for Insert Link.
- **Pasting a URL** over a selection makes `[selection](url)`.
- **Pasting or dropping an image** saves it next to the document (in an `assets/` folder, configurable) and inserts `![](assets/…)`.
- Smart pairing for `*`, `_` and `` ` `` around a selection.

### 3.4 Other features that benefit from the parse

- **Symbols menu and folding for Markdown** switch from heuristics to the parsed headings and blocks, which removes false headings inside code fences.
- **Word count and reading time** in the status bar, counting rendered text rather than markup.

---

## 4. Export: HTML and PDF

### 4.1 Shared pipeline: `MarkdownExporter`

1. Render with `MarkdownDocument.html()`, without source positions.
2. Load it in an **off-screen `WKWebView`** with the normal preview page and wait for `window.quireReady` (highlighting, KaTeX and Mermaid finished). That pipeline already exists, and `PreviewPane.whenRendered` shows the pattern.
3. Read back the rendered DOM. Mermaid is now inline SVG, math is KaTeX markup, and code is highlighted spans.
4. Post-process into the target format.

Doing the rendering once in WebKit guarantees exports look exactly like the preview.

### 4.2 HTML export (**File ▸ Export ▸ HTML…**, `⇧⌘E`)

The output is one self-contained `.html` file:
- `<script>` tags and the `Copy` buttons are removed, so nothing needs JavaScript to display.
- CSS is inlined: the page stylesheet, the highlight.js theme, and KaTeX's CSS with its **WOFF2 fonts embedded as data URIs** (only the fonts the page uses, by scanning the KaTeX output for font classes).
- Mermaid diagrams are inline `<svg>`.
- A light/dark switch through `prefers-color-scheme` is kept.
- Options in the save panel's accessory view:
  - **Images:** embed as data URIs (default) / keep links / copy to a sibling `…_files/` folder
  - **Sanitize raw HTML** (GFM tag filter)
  - **Include table of contents** (from the parsed headings)
  - **Theme:** Light, Dark, or follow the reader's system
- The title comes from front matter `title`, else the first `#` heading, else the file name.

Also add **Edit ▸ Copy as Rich Text** (`⌥⇧⌘C`), which puts the same rendered HTML on the pasteboard as `.html` and `.rtf`. You can then paste formatted text into Mail, Pages, Google Docs, Notion or LinkedIn. It's cheap once the pipeline exists, and people use it a lot.

### 4.3 PDF export (**File ▸ Export ▸ PDF…**)

- Use `WKWebView.printOperation(with:)` with an `NSPrintInfo` set to `jobDisposition = .save` and `jobSavingURL` set to the destination. This produces a **paginated** PDF. `createPDF` would produce one endless page, which isn't what people want.
- Known WebKit quirk: the print operation draws blank unless the web view has a non-zero frame and is in a window hierarchy. Host it in an off-screen, zero-alpha window sized to the paper width.
- Add a print stylesheet in `quire-preview.css` (`@media print`): `break-inside: avoid` on code blocks, tables, figures, diagrams and math; `break-after: avoid` on headings; a light theme forced for print; links shown as text plus a muted URL, as an option.
- Options: paper size and orientation (from Page Setup), margins, **include table of contents**, **page numbers** (drawn through the print info header/footer), **title page from front matter**.
- PDF metadata (title, author from front matter) set through `PDFDocument` after saving.
- **File ▸ Print** for a Markdown document prints the rendered page through the same path, with a "Print Source" item for the old behaviour.

### 4.4 Command line and AppleScript

- `quire --export html|pdf input.md -o out.html` uses the same exporter headless, for scripts and CI.
- AppleScript: `export front document as HTML to POSIX file "…"`.

---

## 5. Order of work

Each stage can ship on its own.

| Stage | Contents | Size | Ships as |
|---|---|---|---|
| **1. Spec baseline** | Spec test runner against the **current** renderer. Record the pass rate | S | Internal |
| **2. New parser** | swift-cmark dependency, `MarkdownDocument`, position mapping, extensions (math, Mermaid, front matter, alerts, footnotes, anchors), preview switched over, scroll sync. Delete the old renderer once the spec tests are at 100% | M–L | 1.1 "Full CommonMark + GFM" |
| **3. Export** | `MarkdownExporter`, HTML export, PDF export, Copy as Rich Text, rendered Print, CLI export | M | 1.1 or 1.2 |
| **4. Styled mode** (stage A) | `MarkdownStyler` with real attributes: heading sizes, bold/italic/code fonts, muted markers, link colour, quote and list indents, editing behaviours from 3.3 | M | 1.2 |
| **5. Live Preview** (stage B) | `MarkupHider` combined with folding, active-block reveal, hidden link URLs, checkbox/bullet/rule widgets | L | 1.3 |
| **6. Rich widgets** | Images, math (SwiftMath + KaTeX fallback), Mermaid snapshots, table auto-format | L | 1.4 |

Stages 2 and 3 give the most value per unit of effort, and they fix the two gaps a reviewer would spot first (partial spec support, no export). Stages 4–6 are what make Quire feel like a writing app.

---

## 6. Risks and how to handle them

| Risk | Mitigation |
|---|---|
| Inline source positions from cmark are imprecise | Use cmark ranges only for outer node boundaries and scan the source for markers. Run position tests over the full spec corpus: every marker range must cover exactly the delimiter characters |
| Re-styling makes typing lag on big files | Parse in the background; style visible plus edited ranges first; chunk the rest; drop back to Styled or Source above size thresholds. Benchmark gate: ≤ 8 ms of main-thread work per keystroke on a 200 KB file (`docs/preview-sample.md` repeated) on an M1 |
| Hidden glyphs confuse cursor movement, selection or IME | Hide only outside the active block, so the cursor never lands inside hidden text. Test arrow keys, word movement, ⌘-arrows, Japanese and Chinese input methods, and VoiceOver on a heading and a link |
| Folding and markup hiding both need the one layout-manager delegate | `FoldManager` stays the single delegate and asks `MarkupHider` for extra hidden ranges. Self-test: fold a section containing hidden markup, unfold it, check the glyph count |
| Real attributes on the text storage leak into saved text, undo or the edited state | The file is saved from `string`, so attributes can't reach the disk. Self-tests check undo is empty and the document stays clean after styling. AI Transform, Text Filters and AppleScript read `string` and are unaffected |
| PDF print operation renders blank or in dark mode | Off-screen window with a real frame; force a light `@media print` theme; self-test that exports a sample and checks the PDF's page count and extracted text |
| KaTeX fonts make HTML exports large | Embed only the fonts used. A typical document with math adds about 100–300 KB |
| Licences | cmark-gfm BSD-2, SwiftMath MIT, plus the already-bundled KaTeX (MIT), Mermaid (MIT) and highlight.js (BSD-3). Add them all to the About box and `Resources/preview/*/LICENSE` |

---

## 7. Definition of done

- CommonMark and GFM spec suites at 100%, run by `swift test`.
- `docs/preview-sample.md` opened in Live Preview looks like the preview pane: headings, emphasis, lists, quotes, task boxes, links, images, math and a Mermaid diagram are all rendered, and each turns back into source when the cursor enters it.
- Typing in a 200 KB Markdown file stays smooth (benchmark above).
- Exported HTML, opened on a different Mac with no internet, shows identical diagrams, math and code highlighting.
- Exported PDF is paginated, with no code block or diagram split across pages, and has page numbers and a table of contents when chosen.
- README updated: the "Limitations" bullet about the partial Markdown renderer and the "no Save as HTML" note are removed, and the new features are documented.
