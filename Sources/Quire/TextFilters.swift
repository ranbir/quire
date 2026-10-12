import AppKit

/// Unix text filters: executables or scripts in the Text Filters folder that
/// receive the selection (or whole document) on stdin; stdout replaces it.
enum TextFilters {
    struct FilterError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Quire")
    }

    static var folder: URL { supportFolder.appendingPathComponent("Text Filters") }

    static func ensureFolder() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples: [(String, String)] = [
            ("Sort Unique.sh", "#!/bin/sh\n# Sort lines and drop duplicates.\nsort -u\n"),
            ("Reverse Characters.sh", "#!/bin/sh\nrev\n"),
            ("Base64 Encode.sh", "#!/bin/sh\nbase64\n"),
            ("Base64 Decode.sh", "#!/bin/sh\nbase64 -D\n"),
            ("URL Decode.sh", "#!/bin/sh\nexec /usr/bin/perl -pe 's/\\+/ /g; s/%([0-9a-fA-F]{2})/chr(hex($1))/ge'\n"),
            ("Word Frequency.sh", "#!/bin/sh\ntr -cs '[:alnum:]' '\\n' | tr '[:upper:]' '[:lower:]' | sort | uniq -c | sort -rn\n"),
        ]
        for (name, body) in samples {
            let url = folder.appendingPathComponent(name)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static func list() -> [URL] {
        ensureFolder()
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func run(filter url: URL, input: String) throws -> String {
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return try run(executable: url, arguments: [], input: input)
        }
        return try run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [url.path], input: input)
    }

    static func run(command: String, input: String) throws -> String {
        try run(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", command], input: input)
    }

    private static func run(executable: URL, arguments: [String], input: String) throws -> String {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run()

        let inData = Data(input.utf8)
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: inData)
            try? stdin.fileHandleForWriting.close()
        }
        var errData = Data()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global().async { errData = stderr.fileHandleForReading.readDataToEndOfFile(); errGroup.leave() }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errGroup.wait()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FilterError(message: "Exited with status \(p.terminationStatus)" + (msg.isEmpty ? "" : ":\n\(msg)"))
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
