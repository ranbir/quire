import Foundation

public struct ProcessResult {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct ProcessError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ProcessRunner {
    /// PATH with the usual package-manager locations prepended.
    public static var defaultEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// Runs a process to completion, feeding `input` on stdin. Never deadlocks on large output.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, input: Data? = nil,
                           environment: [String: String]? = nil) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment ?? defaultEnvironment
        if let cwd { p.currentDirectoryURL = cwd }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : stdin
        p.standardOutput = stdout
        p.standardError = stderr
        try p.run()

        if let input {
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        return ProcessResult(status: p.terminationStatus, stdout: outData, stderr: errData)
    }

    /// Like `run`, but throws with stderr when the exit status is non-zero.
    public static func check(_ executable: String, _ arguments: [String], cwd: URL? = nil, input: Data? = nil,
                             environment: [String: String]? = nil) throws -> String {
        let r = try run(executable, arguments, cwd: cwd, input: input, environment: environment)
        guard r.status == 0 else {
            let msg = r.errorOutput.isEmpty ? r.output.trimmingCharacters(in: .whitespacesAndNewlines) : r.errorOutput
            throw ProcessError("\((executable as NSString).lastPathComponent) exited with status \(r.status)" + (msg.isEmpty ? "" : ":\n\(msg)"))
        }
        return r.output
    }
}
