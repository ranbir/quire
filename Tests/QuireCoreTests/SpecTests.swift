import XCTest
@testable import QuireCore

/// Runs the examples from the CommonMark and GitHub Flavored Markdown specs (vendored in
/// `Spec/`) through `Markdown.html` and compares the output after normalizing insignificant
/// whitespace, as the reference test harness does.
final class SpecTests: XCTestCase {

    struct Example {
        let number: Int
        let section: String
        let extensionName: String?
        let markdown: String
        let html: String
    }

    static let specDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Spec")

    /// Parses the spec's ```` ```… example ```` blocks. Tabs are written as `→` in the spec.
    static func examples(_ file: String) throws -> [Example] {
        let text = try String(contentsOf: specDir.appendingPathComponent(file), encoding: .utf8)
        let fence = String(repeating: "`", count: 32)
        var out: [Example] = []
        var section = ""
        var lines = text.components(separatedBy: "\n")[...]
        while let line = lines.popFirst() {
            if line.hasPrefix("#") { section = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces); continue }
            guard line.hasPrefix(fence + " example") else { continue }
            let ext = line.dropFirst(fence.count + " example".count).trimmingCharacters(in: .whitespaces)
            var md: [String] = [], html: [String] = [], inHTML = false
            while let l = lines.popFirst(), l != fence {
                if l == "." && !inHTML { inHTML = true; continue }
                if inHTML { html.append(l) } else { md.append(l) }
            }
            func join(_ ls: [String]) -> String { ls.isEmpty ? "" : ls.joined(separator: "\n").replacingOccurrences(of: "→", with: "\t") + "\n" }
            out.append(Example(number: out.count + 1, section: section, extensionName: ext.isEmpty ? nil : ext,
                               markdown: join(md), html: join(html)))
        }
        return out
    }

    static let blockTags = "address|article|aside|blockquote|details|dialog|dd|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|summary|table|tbody|td|tfoot|th|thead|tr|ul"

    /// Whitespace-insensitive form of an HTML fragment: drops whitespace around block tags,
    /// collapses runs of whitespace outside `<pre>`, treats `<br />` as `<br>`, and ignores
    /// heading `id`s (Quire adds anchors on purpose).
    static func normalize(_ html: String) -> String {
        var s = html
        func sub(_ pattern: String, _ with: String, _ opts: NSRegularExpression.Options = []) {
            let r = try! NSRegularExpression(pattern: pattern, options: opts)
            s = r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: with)
        }
        sub(#"<(h[1-6])\s+id="[^"]*""#, "<$1")
        sub(#"\s*/>"#, ">")
        // Collapse whitespace outside <pre>…</pre>
        var out = "", rest = s[...]
        while let open = rest.range(of: "<pre") {
            out += collapse(String(rest[..<open.lowerBound]))
            let close = rest[open.lowerBound...].range(of: "</pre>")?.upperBound ?? rest.endIndex
            out += rest[open.lowerBound..<close]
            rest = rest[close...]
        }
        out += collapse(String(rest))
        s = out
        sub(#"\s*(</?(?:\#(blockTags))\b[^>]*>)\s*"#, "$1", .caseInsensitive)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    struct Result { var passed = 0; var total = 0; var failures: [Example] = []; var bySection: [String: (Int, Int)] = [:] }

    /// Core examples are plain CommonMark, so they run with extensions off; extension examples
    /// run with Quire's defaults (and the tag filter for the "Disallowed Raw HTML" one), as
    /// cmark-gfm's own spec runner does. `allExtensions` runs everything with the defaults.
    static func render(_ ex: Example, allExtensions: Bool = false) -> String {
        guard ex.extensionName != nil || allExtensions else { return Markdown.html(ex.markdown, options: .commonMark) }
        var o = MarkdownOptions.default
        o.sanitizeHTML = ex.extensionName == "tagfilter"
        return Markdown.html(ex.markdown, options: o)
    }

    static func run(_ file: String, allExtensions: Bool = false, skipping: Set<Int> = []) throws -> Result {
        var r = Result()
        for ex in try examples(file) where ex.extensionName != "disabled" && !skipping.contains(ex.number) {
            r.total += 1
            let ok = normalize(render(ex, allExtensions: allExtensions)) == normalize(ex.html)
            if ok { r.passed += 1 } else { r.failures.append(ex) }
            let (p, t) = r.bySection[ex.section] ?? (0, 0)
            r.bySection[ex.section] = (p + (ok ? 1 : 0), t + 1)
        }
        return r
    }

    static func report(_ name: String, _ r: Result) -> String {
        let pct = Double(r.passed) / Double(max(r.total, 1)) * 100
        var s = String(format: "%@: %d / %d examples pass (%.1f%%)\n", name, r.passed, r.total, pct)
        for (section, (p, t)) in r.bySection.sorted(by: { $0.key < $1.key }) where p < t {
            s += "  \(section): \(p)/\(t)\n"
        }
        return s
    }

    /// CommonMark 0.31.2 examples whose expected output changed after 0.29, the version
    /// cmark-gfm (and so GitHub) implements. The GFM spec expects what we produce.
    static let commonMark031Changes: [Int: String] = [
        28: "0.31 limits numeric entities to 7 digits (0.29: 8)",
        354: "0.31 treats symbols ($ £ €) as punctuation for emphasis flanking",
        389: "0.30 nests strong emphasis instead of merging it", 417: "0.30 nesting", 425: "0.30 nesting",
        426: "0.30 nesting", 427: "0.30 nesting", 464: "0.30 nesting", 465: "0.30 nesting",
        466: "0.30 nesting", 468: "0.30 nesting",
    ]

    func testCommonMarkSpec() throws {
        let r = try Self.run("commonmark-0.31.2.txt")
        print(Self.report("CommonMark 0.31.2", r))
        let unexpected = r.failures.filter { Self.commonMark031Changes[$0.number] == nil }
        dumpFailures(unexpected)
        XCTAssertEqual(r.total, 652)
        XCTAssertEqual(unexpected.map(\.number), [], Self.report("CommonMark 0.31.2", r))
        // Fails when one of the listed differences gets fixed, so the list stays accurate.
        XCTAssertEqual(Set(r.failures.map(\.number)), Set(Self.commonMark031Changes.keys))
    }

    func testGFMSpec() throws {
        let r = try Self.run("gfm-spec.txt")
        print(Self.report("GFM 0.29", r))
        dumpFailures(r.failures)
        XCTAssertEqual(r.total, 670)
        XCTAssertEqual(r.failures.map(\.number), [], Self.report("GFM 0.29", r))
    }

    /// With every extension on (as in the editor), the only core examples that change are
    /// the ones the extensions exist to change: bare-URL autolinks and `$` math.
    func testGFMSpecWithAllExtensions() throws {
        let r = try Self.run("gfm-spec.txt", allExtensions: true)
        print(Self.report("GFM 0.29, all extensions", r))
        dumpFailures(r.failures)
        let sections = Set(r.failures.map(\.section))
        XCTAssertTrue(sections.isSubset(of: ["Autolinks"]), "\(r.failures.map { "\($0.number) \($0.section)" })")
    }

    func dumpFailures(_ failures: [Example]) {
        guard ProcessInfo.processInfo.environment["QUIRE_SPEC_VERBOSE"] != nil else { return }
        for ex in failures.prefix(40) {
            print("--- Example \(ex.number) (\(ex.section))\n\(ex.markdown)>>> expected\n\(ex.html)>>> got\n\(Self.render(ex))")
        }
    }

    func testNormalizer() {
        XCTAssertEqual(Self.normalize("<p>a\n  b</p>\n<ul>\n<li>x</li>\n</ul>\n"), "<p>a b</p><ul><li>x</li></ul>")
        XCTAssertEqual(Self.normalize("<pre><code>a\n  b\n</code></pre>"), "<pre><code>a\n  b\n</code></pre>")
        XCTAssertEqual(Self.normalize("<h2 id=\"x\">T</h2><br />"), "<h2>T</h2><br>")
    }
}
