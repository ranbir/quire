import Foundation

/// A file or directory on an SSH host.
public struct RemoteLocation: Codable, Hashable {
    public var user: String?
    public var host: String
    public var port: Int?
    public var path: String

    public init(user: String?, host: String, port: Int? = nil, path: String) {
        self.user = user; self.host = host; self.port = port; self.path = path
    }

    /// Accepts `sftp://user@host:port/path`, `ssh://…` or scp-style `user@host:path`.
    public init?(string: String) {
        let s = string.trimmingCharacters(in: .whitespaces)
        if let comps = URLComponents(string: s), let scheme = comps.scheme, ["sftp", "ssh", "scp"].contains(scheme), let host = comps.host {
            self.init(user: comps.user, host: host, port: comps.port, path: comps.path.isEmpty ? "~" : comps.path.removingPercentEncoding ?? comps.path)
            if path.hasPrefix("/~") { path.removeFirst() }
            return
        }
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let target = s[..<colon]
        let path = String(s[s.index(after: colon)...])
        let parts = target.split(separator: "@", maxSplits: 1)
        guard !target.isEmpty, !target.contains("/") else { return nil }
        if parts.count == 2 {
            self.init(user: String(parts[0]), host: String(parts[1]), path: path.isEmpty ? "~" : path)
        } else {
            self.init(user: nil, host: String(target), path: path.isEmpty ? "~" : path)
        }
    }

    public var destination: String { user.map { "\($0)@\(host)" } ?? host }

    public var display: String { "\(destination)\(port.map { ":\($0)" } ?? ""):\(path)" }

    public var urlString: String {
        var c = URLComponents()
        c.scheme = "sftp"; c.user = user; c.host = host; c.port = port
        c.path = path.hasPrefix("/") ? path : "/" + path
        return c.string ?? display
    }

    public var fileName: String { (path as NSString).lastPathComponent }

    public func appending(_ name: String) -> RemoteLocation {
        var l = self
        l.path = path.hasSuffix("/") ? path + name : path + "/" + name
        return l
    }

    public var parent: RemoteLocation {
        var l = self
        let p = (path as NSString).deletingLastPathComponent
        l.path = p.isEmpty ? (path.hasPrefix("/") ? "/" : "~") : p
        return l
    }
}

public struct RemoteEntry: Equatable {
    public let name: String
    public let isDirectory: Bool
}

/// Talks to remote hosts by running the system `ssh`. Authentication is
/// whatever ssh is configured for (keys, agent, ~/.ssh/config); interactive
/// prompts go through SSH_ASKPASS, which the app provides.
public final class SSHClient {
    public var environment: [String: String]
    public var controlDirectory: URL
    public static let sshPath = "/usr/bin/ssh"

    public init(environment: [String: String] = ProcessRunner.defaultEnvironment, controlDirectory: URL) {
        self.environment = environment
        self.controlDirectory = controlDirectory
    }

    /// POSIX single-quote escaping for the remote shell. A leading "~/" is left
    /// unquoted so the remote shell expands it.
    public static func quote(_ path: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + q(String(path.dropFirst(2))) }
        return q(path)
    }

    public func arguments(for loc: RemoteLocation, command: String) -> [String] {
        var args = [
            "-o", "BatchMode=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
            "-o", "ControlMaster=auto", "-o", "ControlPersist=120",
            "-o", "ControlPath=\(controlDirectory.path)/%C",
        ]
        if let p = loc.port { args += ["-p", String(p)] }
        args += ["--", loc.destination, command]
        return args
    }

    func ssh(_ loc: RemoteLocation, _ command: String, input: Data? = nil) throws -> Data {
        try? FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        let r = try ProcessRunner.run(Self.sshPath, arguments(for: loc, command: command), input: input, environment: environment)
        guard r.status == 0 else {
            throw ProcessError(r.errorOutput.isEmpty ? "ssh to \(loc.destination) failed (status \(r.status))" : r.errorOutput)
        }
        return r.stdout
    }

    public static func parseListing(_ output: String) -> [RemoteEntry] {
        output.split(separator: "\n").compactMap { line in
            var name = String(line)
            guard !name.isEmpty, name != "./", name != "../" else { return nil }
            let isDir = name.hasSuffix("/")
            if isDir { name.removeLast() }
            if name.hasSuffix("@") || name.hasSuffix("*") || name.hasSuffix("|") || name.hasSuffix("=") { name.removeLast() }
            return RemoteEntry(name: name, isDirectory: isDir)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Directory listing. Also resolves the directory's absolute path.
    public func list(_ loc: RemoteLocation) throws -> (path: String, entries: [RemoteEntry]) {
        let out = String(decoding: try ssh(loc, "cd \(Self.quote(loc.path)) && pwd && LC_ALL=C ls -1ApL"), as: UTF8.self)
        var lines = out.components(separatedBy: "\n")
        let pwd = lines.isEmpty ? loc.path : lines.removeFirst()
        return (pwd, Self.parseListing(lines.joined(separator: "\n")))
    }

    public func read(_ loc: RemoteLocation) throws -> Data {
        try ssh(loc, "cat -- \(Self.quote(loc.path))")
    }

    /// Writes via a temp file and rename, preserving the existing file's mode.
    public func write(_ data: Data, to loc: RemoteLocation) throws {
        let p = Self.quote(loc.path)
        let tmp = Self.quote(loc.path + ".quire-tmp")
        let cmd = "cat > \(tmp) && { [ ! -e \(p) ] || chmod \"$(stat -c %a \(p) 2>/dev/null || stat -f %Lp \(p))\" \(tmp); } && mv -f \(tmp) \(p)"
        _ = try ssh(loc, cmd, input: data)
    }
}
