import Foundation

public enum ChangeMarker: Equatable {
    case added, modified
    /// Lines were removed just above this line.
    case deletedAbove
}

extension LineDiff {
    /// Gutter markers for `new` relative to `old`, keyed by 0-based line in `new`.
    public static func changeMarkers(old: String, new: String) -> [Int: ChangeMarker] {
        var markers: [Int: ChangeMarker] = [:]
        var newLine = 0
        var pendingDeletes = 0
        var pendingInserts: [Int] = []

        func flush() {
            if !pendingInserts.isEmpty {
                let modified = min(pendingDeletes, pendingInserts.count)
                for (k, l) in pendingInserts.enumerated() { markers[l] = k < modified ? .modified : .added }
            } else if pendingDeletes > 0 {
                markers[newLine] = markers[newLine] ?? .deletedAbove
            }
            pendingDeletes = 0
            pendingInserts = []
        }

        for op in ops(old: lines(old), new: lines(new)) {
            switch op {
            case .equal: flush(); newLine += 1
            case .delete: pendingDeletes += 1
            case .insert: pendingInserts.append(newLine); newLine += 1
            }
        }
        flush()
        // A deletion at the very end is drawn on the last line.
        if let end = markers[newLine], end == .deletedAbove, newLine > 0 {
            markers[newLine] = nil
            markers[newLine - 1] = markers[newLine - 1] ?? .deletedAbove
        }
        return markers
    }
}

public struct GitStatusEntry: Equatable {
    public let path: String
    /// Two-letter porcelain code, e.g. " M", "A ", "??".
    public let code: String
    public var summary: String {
        switch code {
        case "??": return "untracked"
        case "!!": return "ignored"
        default:
            let staged = code.first!, unstaged = code.last!
            func word(_ c: Character) -> String? {
                switch c {
                case "M": return "modified"; case "A": return "added"; case "D": return "deleted"
                case "R": return "renamed"; case "C": return "copied"; case "U": return "conflict"
                default: return nil
                }
            }
            return [word(staged).map { "\($0) (staged)" }, word(unstaged)].compactMap { $0 }.joined(separator: ", ")
        }
    }
}

public struct BlameLine: Equatable {
    public let commit: String
    public let author: String
    public let date: Date
    public let summary: String
    public let text: String
}

public struct GitRepository {
    public let root: URL
    public static var gitPath = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    public init(root: URL) { self.root = root }

    /// The repository containing `url` (a file or directory), if any.
    public static func containing(_ url: URL) -> GitRepository? {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let dir = exists && isDir.boolValue ? url : url.deletingLastPathComponent()
        guard let out = try? ProcessRunner.check(gitPath, ["rev-parse", "--show-toplevel"], cwd: dir) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : GitRepository(root: URL(fileURLWithPath: path))
    }

    @discardableResult
    public func git(_ args: [String], input: Data? = nil) throws -> String {
        var env = ProcessRunner.defaultEnvironment
        env["GIT_PAGER"] = "cat"; env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_OPTIONAL_LOCKS"] = "0"
        return try ProcessRunner.check(Self.gitPath, ["-c", "color.ui=false"] + args, cwd: root, input: input, environment: env)
    }

    public func relativePath(_ file: URL) -> String {
        let f = file.resolvingSymlinksInPath().path, r = root.resolvingSymlinksInPath().path
        return f.hasPrefix(r + "/") ? String(f.dropFirst(r.count + 1)) : file.lastPathComponent
    }

    public func currentBranch() -> String? {
        if let b = try? git(["symbolic-ref", "--short", "-q", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty { return b }
        return (try? git(["rev-parse", "--short", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// File contents at HEAD, or nil when the file isn't tracked / there are no commits.
    public func headContents(of file: URL) -> String? {
        guard let out = try? git(["show", "HEAD:\(relativePath(file))"]) else { return nil }
        return TextCodec.normalizeLineEndings(out)
    }

    public func status() throws -> [GitStatusEntry] {
        let out = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        var entries: [GitStatusEntry] = []
        var parts = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let p = parts.popFirst() {
            guard p.count > 3 else { continue }
            let code = String(p.prefix(2))
            entries.append(GitStatusEntry(path: String(p.dropFirst(3)), code: code))
            if code.first == "R" || code.first == "C" { _ = parts.popFirst() }   // original path follows
        }
        return entries
    }

    public func blame(_ file: URL) throws -> [BlameLine] {
        let out = try git(["blame", "--porcelain", "--", relativePath(file)])
        var lines: [BlameLine] = []
        var info: [String: (author: String, time: Date, summary: String)] = [:]
        var commit = "", author = "", time = Date(timeIntervalSince1970: 0), summary = ""
        for raw in out.components(separatedBy: "\n") {
            if raw.hasPrefix("\t") {
                if info[commit] == nil { info[commit] = (author, time, summary) }
                let i = info[commit]!
                lines.append(BlameLine(commit: String(commit.prefix(8)), author: i.author, date: i.time, summary: i.summary, text: String(raw.dropFirst())))
            } else if raw.hasPrefix("author ") {
                author = String(raw.dropFirst(7))
            } else if raw.hasPrefix("author-time ") {
                time = Date(timeIntervalSince1970: TimeInterval(raw.dropFirst(12)) ?? 0)
            } else if raw.hasPrefix("summary ") {
                summary = String(raw.dropFirst(8))
            } else if let first = raw.split(separator: " ").first, first.count == 40, first.allSatisfy(\.isHexDigit) {
                commit = String(first)
                if let i = info[commit] { author = i.author; time = i.time; summary = i.summary }
            }
        }
        return lines
    }

    public func log(_ file: URL?, limit: Int = 200) throws -> String {
        var args = ["log", "-n", "\(limit)", "--date=short", "--pretty=format:%h  %ad  %<(18,trunc)%an  %s"]
        if let file { args += ["--follow", "--", relativePath(file)] }
        return try git(args)
    }

    public func diff(_ file: URL?, staged: Bool = false) throws -> String {
        var args = ["diff"]
        if staged { args.append("--cached") }
        if let file { args += ["--", relativePath(file)] }
        return try git(args)
    }

    public func stage(_ file: URL) throws { try git(["add", "--", relativePath(file)]) }
    public func unstage(_ file: URL) throws { try git(["restore", "--staged", "--", relativePath(file)]) }
    public func discardChanges(_ file: URL) throws { try git(["checkout", "HEAD", "--", relativePath(file)]) }

    public func commit(message: String, all: Bool = false) throws -> String {
        try git(["commit"] + (all ? ["-a"] : []) + ["-F", "-"], input: Data(message.utf8))
    }
}
