import Foundation

public enum LineDiff {
    public enum Op: Equatable {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    public static func lines(_ s: String) -> [String] {
        let (l, _) = TextTransforms.splitLines(s)
        return s.isEmpty ? [] : l
    }

    public static func ops(old: [String], new: [String]) -> [Op] {
        let diff = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var result: [Op] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count && removed.contains(i) {
                result.append(.delete(old[i])); i += 1
            } else if j < new.count && inserted.contains(j) {
                result.append(.insert(new[j])); j += 1
            } else if i < old.count && j < new.count {
                result.append(.equal(old[i])); i += 1; j += 1
            } else if i < old.count {
                result.append(.delete(old[i])); i += 1
            } else {
                result.append(.insert(new[j])); j += 1
            }
        }
        return result
    }

    /// Standard unified diff; returns "" when the inputs are identical.
    public static func unified(old: String, new: String, oldName: String, newName: String, context: Int = 3) -> String {
        let o = ops(old: lines(old), new: lines(new))
        let changed = o.indices.filter { if case .equal = o[$0] { return false } else { return true } }
        guard !changed.isEmpty else { return "" }

        // Group changes into hunks separated by more than 2*context equal lines.
        var hunks: [ClosedRange<Int>] = []
        var start = max(0, changed[0] - context)
        var end = min(o.count - 1, changed[0] + context)
        for c in changed.dropFirst() {
            if c - context <= end + 1 {
                end = min(o.count - 1, c + context)
            } else {
                hunks.append(start...end)
                start = max(0, c - context); end = min(o.count - 1, c + context)
            }
        }
        hunks.append(start...end)

        // Line numbers at each op index.
        var oldLine = [Int](), newLine = [Int]()
        var a = 1, b = 1
        for op in o {
            oldLine.append(a); newLine.append(b)
            switch op {
            case .equal: a += 1; b += 1
            case .delete: a += 1
            case .insert: b += 1
            }
        }

        var out = "--- \(oldName)\n+++ \(newName)\n"
        for h in hunks {
            var oc = 0, nc = 0, body = ""
            for k in h {
                switch o[k] {
                case .equal(let s): body += " \(s)\n"; oc += 1; nc += 1
                case .delete(let s): body += "-\(s)\n"; oc += 1
                case .insert(let s): body += "+\(s)\n"; nc += 1
                }
            }
            let os = oc == 0 ? oldLine[h.lowerBound] - 1 : oldLine[h.lowerBound]
            let ns = nc == 0 ? newLine[h.lowerBound] - 1 : newLine[h.lowerBound]
            out += "@@ -\(os),\(oc) +\(ns),\(nc) @@\n" + body
        }
        return out
    }
}

extension LineDiff {
    public enum LineKind: Equatable { case inserted, deleted }

    /// Old and new interleaved as one text (deleted lines before their replacements),
    /// with the UTF-16 range of every changed line, for an inline "changes" view.
    public static func interleaved(old: String, new: String) -> (text: String, changes: [(range: NSRange, kind: LineKind)]) {
        var text = "", changes: [(NSRange, LineKind)] = []
        var location = 0
        for op in ops(old: lines(old), new: lines(new)) {
            let line: String, kind: LineKind?
            switch op {
            case .equal(let l): line = l; kind = nil
            case .delete(let l): line = l; kind = .deleted
            case .insert(let l): line = l; kind = .inserted
            }
            let length = (line as NSString).length + 1
            text += line + "\n"
            if let kind { changes.append((NSRange(location: location, length: length), kind)) }
            location += length
        }
        return (text, changes)
    }
}
