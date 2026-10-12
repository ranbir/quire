import Foundation

/// GitHub table editing: Tab and Shift-Tab move between cells and Return adds a row, each
/// re-padding the columns so the pipes line up.
extension MarkdownEditing {

    enum Align { case none, left, center, right }

    struct Table {
        var range: NSRange          // whole lines, without the final line break
        var rows: [[String]]        // header, then body rows (the delimiter row excluded)
        var aligns: [Align]
        var cursorRow: Int          // index into rows; the delimiter row counts as the header
        var cursorColumn: Int
    }

    static let delimiterRow = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)

    /// Cells of one row: split on pipes that aren't escaped or inside code spans.
    static func cells(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inCode = false
        var escaped = false
        for ch in line {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" { cur.append(ch); escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { out.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        out.append(cur)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), !out.isEmpty { out.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|"), !out.isEmpty { out.removeLast() }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The table around `cursor`, if the cursor's line belongs to one.
    static func table(in text: String, cursor: Int) -> Table? {
        let ns = text as NSString
        func hasPipe(_ r: NSRange) -> Bool { ns.substring(with: r).contains("|") }
        let here = lineRange(ns, cursor)
        guard hasPipe(here) else { return nil }
        var first = here, last = here
        while first.location > 0 {
            let prev = lineRange(ns, first.location - 1)
            guard hasPipe(prev), !ns.substring(with: prev).trimmingCharacters(in: .whitespaces).isEmpty else { break }
            first = prev
        }
        while NSMaxRange(last) < ns.length {
            let next = lineRange(ns, NSMaxRange(last) + 1)
            guard next.length > 0, hasPipe(next) else { break }
            last = next
        }
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let lines = ns.substring(with: range).components(separatedBy: "\n")
        guard lines.count >= 2,
              delimiterRow.firstMatch(in: lines[1], range: NSRange(location: 0, length: (lines[1] as NSString).length)) != nil else { return nil }
        let header = cells(lines[0])
        let columns = header.count
        guard columns > 0 else { return nil }
        let aligns: [Align] = cells(lines[1]).map { c in
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            default: return .none
            }
        }
        var rows = [header]
        for l in lines.dropFirst(2) {
            var c = cells(l)
            if c.count < columns { c += Array(repeating: "", count: columns - c.count) }
            rows.append(Array(c.prefix(columns)))
        }
        // Where the cursor is: row (the delimiter row maps to the header) and column.
        let lineIndex = ns.substring(with: NSRange(location: range.location, length: here.location - range.location)).components(separatedBy: "\n").count - 1
        let row = lineIndex <= 1 ? 0 : lineIndex - 1
        let before = ns.substring(with: NSRange(location: here.location, length: cursor - here.location))
        var column = cells(before + "x").count - 1
        if !before.trimmingCharacters(in: .whitespaces).hasPrefix("|") { column = max(column, 0) }
        column = min(max(column, 0), columns - 1)
        return Table(range: range, rows: rows, aligns: Array((aligns + Array(repeating: Align.none, count: columns)).prefix(columns)),
                     cursorRow: row, cursorColumn: column)
    }

    static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { n, u in
            // East Asian wide characters take two columns in a monospaced font.
            let v = u.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v)
            if u.properties.generalCategory == .nonspacingMark { return n }
            return n + (wide ? 2 : 1)
        }
    }

    /// The table as aligned text, and where each cell's text starts (UTF-16 offsets).
    static func render(_ t: Table) -> (text: String, cellStarts: [[Int]]) {
        let columns = t.rows[0].count
        var widths = Array(repeating: 3, count: columns)
        for r in t.rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], width(c)) } }
        var text = ""
        var starts: [[Int]] = []
        func pad(_ c: String, _ i: Int) -> String {
            let gap = widths[i] - width(c)
            switch t.aligns[i] {
            case .right: return String(repeating: " ", count: gap) + c
            case .center: return String(repeating: " ", count: gap / 2) + c + String(repeating: " ", count: gap - gap / 2)
            default: return c + String(repeating: " ", count: gap)
            }
        }
        for (ri, r) in t.rows.enumerated() {
            var line = "|"
            var rowStarts: [Int] = []
            for (i, c) in r.enumerated() {
                line += " "
                let padded = pad(c, i)
                let lead = padded.prefix { $0 == " " }.count
                rowStarts.append((text as NSString).length + (line as NSString).length + (c.isEmpty ? 0 : lead))
                line += padded + " |"
            }
            text += line + "\n"
            starts.append(rowStarts)
            if ri == 0 {
                var d = "|"
                for i in 0..<columns {
                    let dashes = String(repeating: "-", count: widths[i])
                    switch t.aligns[i] {
                    case .left: d += " :" + dashes.dropFirst() + " |"
                    case .right: d += " " + dashes.dropFirst() + ": |"
                    case .center: d += " :" + dashes.dropFirst(2) + ": |"
                    case .none: d += " " + dashes + " |"
                    }
                }
                text += d + "\n"
            }
        }
        text.removeLast()
        return (text, starts)
    }

    /// Formats the table at the cursor and moves to the next cell (or the previous one),
    /// adding a row after the last cell. Nil when the cursor isn't in a table.
    public static func tableTab(_ text: String, cursor: Int, backward: Bool = false) -> Edit? {
        guard var t = table(in: text, cursor: cursor) else { return nil }
        let columns = t.rows[0].count
        var row = t.cursorRow, col = t.cursorColumn + (backward ? -1 : 1)
        if col >= columns { col = 0; row += 1 }
        if col < 0 { col = columns - 1; row = max(0, row - 1) }
        if row >= t.rows.count { t.rows.append(Array(repeating: "", count: columns)) }
        let (out, starts) = render(t)
        return Edit(range: t.range, replacement: out, selection: NSRange(location: t.range.location + starts[row][col], length: (t.rows[row][col] as NSString).length))
    }

    /// Return at the end of a table row: formats the table and starts a new row below.
    public static func tableNewline(_ text: String, cursor: Int) -> Edit? {
        let ns = text as NSString
        let line = lineRange(ns, cursor)
        guard cursor == NSMaxRange(line), var t = table(in: text, cursor: cursor) else { return nil }
        let columns = t.rows[0].count
        let row = t.cursorRow + 1
        t.rows.insert(Array(repeating: "", count: columns), at: min(row, t.rows.count))
        let (out, starts) = render(t)
        return Edit(range: t.range, replacement: out, selection: NSRange(location: t.range.location + starts[row][0], length: 0))
    }

    /// The table at the cursor, re-padded. Nil when there's no table or nothing changes.
    public static func formatTable(_ text: String, cursor: Int) -> Edit? {
        guard let t = table(in: text, cursor: cursor) else { return nil }
        let (out, starts) = render(t)
        guard out != (text as NSString).substring(with: t.range) else { return nil }
        return Edit(range: t.range, replacement: out, selection: NSRange(location: t.range.location + starts[t.cursorRow][t.cursorColumn], length: 0))
    }
}
