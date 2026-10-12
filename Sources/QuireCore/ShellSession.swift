import Foundation

/// A long-lived shell for worksheets: the working directory, variables and
/// functions persist between commands. Each command's stdin is /dev/null so
/// it can't swallow the protocol; stdout and stderr are merged.
public final class ShellSession {
    public let shell: String
    public private(set) var directory: URL
    public var environment: [String: String]

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let lock = NSLock()
    private var signal = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "quire.shell-session")

    public init(shell: String = "/bin/zsh", directory: URL, environment: [String: String] = ProcessRunner.defaultEnvironment) {
        self.shell = shell
        self.directory = directory
        var env = environment
        env["TERM"] = "dumb"; env["NO_COLOR"] = "1"; env["CLICOLOR"] = "0"
        env["PAGER"] = "cat"; env["GIT_PAGER"] = "cat"; env["GIT_TERMINAL_PROMPT"] = "0"
        self.environment = env
    }

    deinit { terminate() }

    public var isRunning: Bool { process?.isRunning ?? false }

    private func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = shell.hasSuffix("zsh") ? ["-f"] : []   // no rc files: predictable output
        p.environment = environment
        p.currentDirectoryURL = directory
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.lock.lock(); self.buffer.append(d); self.lock.unlock()
            self.signal.signal()
        }
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
    }

    /// Kills the shell; the next command starts a fresh one in the last known directory.
    public func terminate() {
        if let p = process, p.isRunning {
            // Stop whatever the shell is running too, not just the shell.
            _ = try? ProcessRunner.run("/usr/bin/pkill", ["-TERM", "-P", String(p.processIdentifier)])
            p.terminate()
        }
        process = nil
        input = nil
        signal.signal()
    }

    public struct Output {
        public let text: String
        public let status: Int32
        public let timedOut: Bool
    }

    /// Runs `command` synchronously. Returns output without the protocol sentinel.
    public func run(_ command: String, timeout: TimeInterval = 600) throws -> Output {
        if process?.isRunning != true { try start() }
        let marker = "__QUIRE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        lock.lock(); buffer = Data(); lock.unlock()
        signal = DispatchSemaphore(value: 0)

        let script = "{\n\(command)\n} </dev/null 2>&1\nprintf '\\n%s %d %s\\n' \(marker) $? \"$PWD\"\n"
        input?.write(Data(script.utf8))

        let deadline = Date().addingTimeInterval(timeout)
        let markerData = Data(marker.utf8)
        while true {
            lock.lock()
            let found = buffer.range(of: markerData)
            let snapshot = buffer
            lock.unlock()
            if let found, let nl = snapshot[found.upperBound...].firstIndex(of: 10) {
                // "\n<marker> <status> <pwd>\n"
                let tail = String(decoding: snapshot[found.upperBound..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                let status = Int32(tail.split(separator: " ").first ?? "") ?? -1
                let pwd = tail.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)
                if let pwd { directory = URL(fileURLWithPath: pwd) }
                var out = snapshot[..<found.lowerBound]
                if out.last == 10 { out = out.dropLast() }
                return Output(text: String(decoding: out, as: UTF8.self), status: status, timedOut: false)
            }
            if process?.isRunning != true {
                return Output(text: String(decoding: snapshot, as: UTF8.self), status: -1, timedOut: false)
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                terminate()
                return Output(text: String(decoding: snapshot, as: UTF8.self), status: -1, timedOut: true)
            }
            _ = signal.wait(timeout: .now() + min(remaining, 0.5))
        }
    }

    /// Runs on a private serial queue and calls back on the main queue.
    public func runAsync(_ command: String, timeout: TimeInterval = 600, completion: @escaping (Result<Output, Error>) -> Void) {
        queue.async {
            let r = Result { try self.run(command, timeout: timeout) }
            DispatchQueue.main.async { completion(r) }
        }
    }
}
