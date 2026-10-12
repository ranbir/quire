import AppKit
import QuireCore

/// Remote editing over SSH/SFTP. Files are downloaded to a cache folder,
/// edited locally, and uploaded on every save.
enum RemoteFiles {
    static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Quire/Remote")
    }

    /// ssh environment: password and host-key prompts are answered by this
    /// app's own binary running in askpass mode (see `Askpass`).
    static let client: SSHClient = {
        var env = ProcessRunner.defaultEnvironment
        if let exe = Bundle.main.executablePath {
            env["SSH_ASKPASS"] = exe
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env[Askpass.environmentKey] = "1"
        }
        return SSHClient(environment: env, controlDirectory: cacheFolder.appendingPathComponent("ssh"))
    }()

    static func cacheURL(for loc: RemoteLocation) -> URL {
        var path = loc.path
        if path.hasPrefix("~") { path = "home" + path.dropFirst() }
        let host = "\(loc.user.map { "\($0)@" } ?? "")\(loc.host)\(loc.port.map { "_\($0)" } ?? "")"
        return cacheFolder.appendingPathComponent(host).appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    static var recentServers: [String] {
        get { UserDefaults.standard.stringArray(forKey: "remote.recentServers") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(15)), forKey: "remote.recentServers") }
    }

    static func remember(_ loc: RemoteLocation) {
        var server = loc
        server.path = (loc.path as NSString).deletingLastPathComponent
        if server.path.isEmpty { server.path = "~" }
        let s = server.display
        recentServers = [s] + recentServers.filter { $0 != s }
    }

    /// Downloads and opens a remote file as a document.
    static func open(_ loc: RemoteLocation, completion: ((Error?) -> Void)? = nil) {
        if let existing = NSDocumentController.shared.documents.first(where: { ($0 as? Document)?.remote == loc }) as? Document {
            existing.showWindows(); completion?(nil); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> URL in
                let data = try client.read(loc)
                let url = cacheURL(for: loc)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                return url
            }
            DispatchQueue.main.async {
                switch result {
                case .failure(let e):
                    if let completion { completion(e) } else { NSApp.presentError(e) }
                case .success(let url):
                    remember(loc)
                    NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { doc, _, error in
                        if let error {
                            if let completion { completion(error) } else { NSApp.presentError(error) }
                            return
                        }
                        guard let d = doc as? Document else { return }
                        d.remote = loc
                        d.language = Languages.detect(filename: loc.fileName, firstLine: d.loadedText.split(separator: "\n").first.map(String.init))
                        if d.windowControllers.isEmpty { d.makeWindowControllers() }
                        d.showWindows()
                        d.editor.setLanguage(d.language ?? Languages.plainText)
                        d.editor.refreshGit(reloadHead: true)
                        completion?(nil)
                    }
                }
            }
        }
    }
}

/// Browse a remote host's files over SSH and open them for editing.
final class RemoteBrowserWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate {
    static let shared = RemoteBrowserWindowController()

    private let serverField = NSComboBox()
    private let pathLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private var location: RemoteLocation?
    private var entries: [RemoteEntry] = []

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Open from SFTP Server"
        super.init(window: w)
        w.delegate = self
        w.setFrameAutosaveName("QuireRemoteBrowser")
        if !w.setFrameUsingName("QuireRemoteBrowser") { w.center() }
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        serverField.placeholderString = "user@host:/path   or   sftp://user@host:port/path"
        serverField.addItems(withObjectValues: RemoteFiles.recentServers)
        serverField.completes = true
        serverField.target = self
        serverField.action = #selector(connect(_:))
        let go = NSButton(title: "Connect", target: self, action: #selector(connect(_:)))
        go.bezelStyle = .rounded
        go.keyEquivalent = "\r"
        let up = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Enclosing folder")!, target: self, action: #selector(goUp(_:)))
        up.bezelStyle = .rounded
        up.toolTip = "Enclosing folder"
        let newFile = NSButton(title: "New File…", target: self, action: #selector(newFile(_:)))
        newFile.bezelStyle = .rounded

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Name"
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.style = .inset
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table

        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.stringValue = "Uses your ssh setup (keys, agent, ~/.ssh/config). Passwords are asked for when needed and never stored."
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let top = NSStackView(views: [serverField, go])
        let nav = NSStackView(views: [up, pathLabel, newFile])
        let bottom = NSStackView(views: [spinner, status])
        let stack = NSStackView(views: [top, nav, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            nav.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            bottom.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -24),
        ])
        window?.initialFirstResponder = serverField
    }

    func showBrowser() {
        serverField.removeAllItems()
        serverField.addItems(withObjectValues: RemoteFiles.recentServers)
        if serverField.stringValue.isEmpty, let first = RemoteFiles.recentServers.first { serverField.stringValue = first }
        showWindow(nil)
        window?.makeFirstResponder(serverField)
    }

    private func busy(_ on: Bool, _ message: String = "") {
        on ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        status.stringValue = message
    }

    @objc private func connect(_ sender: Any?) {
        guard let loc = RemoteLocation(string: serverField.stringValue) else {
            busy(false, "Enter a location like user@example.com:/var/www")
            NSSound.beep(); return
        }
        list(loc)
    }

    private func list(_ loc: RemoteLocation) {
        busy(true, "Connecting to \(loc.destination)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try RemoteFiles.client.list(loc) }
            DispatchQueue.main.async {
                switch r {
                case .success(let (path, entries)):
                    var resolved = loc
                    resolved.path = path
                    self.location = resolved
                    self.entries = entries
                    self.table.reloadData()
                    self.pathLabel.stringValue = path
                    self.serverField.stringValue = resolved.display
                    RemoteFiles.remember(resolved.appending("x"))
                    self.busy(false, "\(entries.count) item\(entries.count == 1 ? "" : "s")")
                case .failure(let e):
                    // Maybe it's a file, not a directory: try opening it.
                    if self.location == nil || loc.path != self.location?.path, !loc.path.hasSuffix("/") {
                        self.busy(true, "Opening \(loc.fileName)…")
                        RemoteFiles.open(loc) { err in
                            self.busy(false, err.map { _ in e.localizedDescription } ?? "Opened \(loc.fileName)")
                        }
                    } else {
                        self.busy(false, e.localizedDescription)
                    }
                }
            }
        }
    }

    @objc private func goUp(_ sender: Any?) {
        guard let loc = location else { NSSound.beep(); return }
        list(loc.parent)
    }

    @objc private func openSelected(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, let loc = location else { return }
        let entry = entries[row]
        let target = loc.appending(entry.name)
        if entry.isDirectory {
            list(target)
        } else {
            busy(true, "Downloading \(entry.name)…")
            RemoteFiles.open(target) { [weak self] err in
                self?.busy(false, err?.localizedDescription ?? "Opened \(entry.name)")
            }
        }
    }

    @objc private func newFile(_ sender: Any?) {
        guard let loc = location else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "New Remote File"
        a.informativeText = "Create a file in \(loc.path):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty, !field.stringValue.contains("/") else { return }
        let target = loc.appending(field.stringValue)
        busy(true, "Creating \(field.stringValue)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try RemoteFiles.client.write(Data(), to: target) }
            DispatchQueue.main.async {
                if case .failure(let e) = r { self.busy(false, e.localizedDescription); return }
                self.list(loc)
                RemoteFiles.open(target)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, window?.firstResponder === table { openSelected(nil) } else { super.keyDown(with: event) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: e.isDirectory ? "folder" : "doc", accessibilityDescription: nil)!)
        icon.contentTintColor = e.isDirectory ? .systemBlue : .secondaryLabelColor
        let label = NSTextField(labelWithString: e.name)
        label.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// When ssh needs a password or a host-key confirmation it runs
/// $SSH_ASKPASS — this same executable — with the prompt as its argument.
/// We show a small dialog and print the answer to stdout.
enum Askpass {
    static let environmentKey = "QUIRE_ASKPASS"

    static var isRequested: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }

    static func run() -> Never {
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "SSH"
        alert.informativeText = prompt.isEmpty ? "Password:" : prompt
        let isConfirmation = prompt.lowercased().contains("yes/no")
        var field: NSSecureTextField?
        if isConfirmation {
            alert.messageText = "Unknown SSH host"
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
        } else {
            let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            alert.accessoryView = f
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = f
            field = f
        }
        alert.window.level = .floating
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { exit(1) }
        let answer = isConfirmation ? "yes" : (field?.stringValue ?? "")
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        exit(0)
    }
}
