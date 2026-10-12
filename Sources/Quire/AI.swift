import AppKit
import QuireCore
import Security

extension Notification.Name {
    static let aiProvidersChanged = Notification.Name("QuireAIProvidersChanged")
}

/// API keys, one generic-password item per provider id. Never written to disk by Quire.
/// Reading a secret can make macOS ask for permission, so secrets are read only
/// when a request is sent and then cached for the rest of the session; `has`
/// checks for an item without reading it, which never prompts.
enum Keychain {
    private static let service = "local.quire.editor.ai"
    private static var cache: [String: String] = [:]

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        if let v = cache[account] { return v }
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let v = String(data: data, encoding: .utf8) else { return nil }
        cache[account] = v
        return v
    }

    static func has(_ account: String) -> Bool {
        if cache[account] != nil { return true }
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    static func set(_ value: String, for account: String) {
        guard !value.isEmpty else { delete(account); return }
        guard cache[account] != value else { return }
        cache[account] = value
        let data = Data(value.utf8)
        if SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "Quire AI API key"
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        cache[account] = nil
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// The provider list, stored in ~/Library/Application Support/Quire/AI Providers.json.
enum AIStore {
    static var fileURL: URL { Prefs.supportFolder.appendingPathComponent("AI Providers.json") }

    private static var cached: AIProviderList?

    static var list: AIProviderList {
        get {
            if let cached { return cached }
            let l = AIProviderList.load(from: fileURL)
            cached = l
            return l
        }
        set {
            cached = newValue
            do { try newValue.save(to: fileURL) } catch { NSApp.presentError(error) }
            NotificationCenter.default.post(name: .aiProvidersChanged, object: nil)
        }
    }

    static func reload() { cached = nil; NotificationCenter.default.post(name: .aiProvidersChanged, object: nil) }

    /// Reads the secret (may prompt once per session); use only when sending a request.
    static func key(for p: AIProvider) -> String? { p.needsKey ? Keychain.get(p.id) : nil }

    static func hasKey(_ p: AIProvider) -> Bool { !p.needsKey || Keychain.has(p.id) }

    /// The default provider, ready to call, or nil after telling the user what's missing.
    static func readyProvider() -> (AIProvider, String?)? {
        guard let p = list.defaultProvider else {
            missing("No AI model is set up", "Add a provider — a hosted service with your API key, or a local server such as Ollama or LM Studio.")
            return nil
        }
        if p.model.isEmpty { missing("“\(p.name)” has no model", "Choose a model for it in AI Models."); return nil }
        if !hasKey(p) { missing("“\(p.name)” needs an API key", "Enter it in AI Models. It’s stored in your Keychain."); return nil }
        return (p, nil)
    }

    private static func missing(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: "Open AI Models")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { AISettingsWindowController.shared.showWindow(nil) }
    }
}

// MARK: - AI Models window

final class AISettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSComboBoxDelegate, NSTextViewDelegate {
    static let shared = AISettingsWindowController()

    private let table = NSTableView()
    private let addRemove = NSSegmentedControl(labels: ["+", "−"], trackingMode: .momentary, target: nil, action: nil)
    private let nameField = NSTextField()
    private let formatPopup = NSPopUpButton()
    private let baseURLField = NSTextField()
    private let modelBox = NSComboBox()
    private let fetchButton = NSButton(title: "Fetch Models", target: nil, action: nil)
    private let needsKeyCheck = NSButton(checkboxWithTitle: "Requires an API key", target: nil, action: nil)
    private let keyField = NSSecureTextField()
    private let headersView = NSTextView()
    private let defaultButton = NSButton(title: "Use as Default", target: nil, action: nil)
    private let forgetKeyButton = NSButton(title: "Forget Key", target: nil, action: nil)
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let detail = NSGridView()
    private var providers: [AIProvider] = []
    private var defaultID: String?
    private var work: Task<Void, Never>?
    /// The provider the form is showing, so late end-editing events can't land on a newly selected row.
    private var editingID: String?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AI Models"
        window.minSize = NSSize(width: 640, height: 380)
        super.init(window: window)
        window.setFrameAutosaveName("QuireAIModels")
        build()
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var selected: AIProvider? {
        providers.indices.contains(table.selectedRow) ? providers[table.selectedRow] : nil
    }

    private func build() {
        guard let content = window?.contentView else { return }

        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        addRemove.target = self
        addRemove.action = #selector(addOrRemove(_:))
        addRemove.segmentStyle = .smallSquare

        let left = NSStackView(views: [scroll, addRemove])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 0
        scroll.widthAnchor.constraint(equalToConstant: 210).isActive = true

        for f in AIWireFormat.allCases { formatPopup.addItem(withTitle: f.displayName); formatPopup.lastItem?.representedObject = f.rawValue }
        formatPopup.target = self; formatPopup.action = #selector(fieldChanged(_:))
        for f in [nameField, baseURLField, keyField] { f.delegate = self }
        modelBox.delegate = self
        modelBox.completes = true
        modelBox.numberOfVisibleItems = 14
        modelBox.target = self; modelBox.action = #selector(fieldChanged(_:))
        baseURLField.placeholderString = "https://api.example.com/v1"
        keyField.placeholderString = "Stored in your Keychain"
        needsKeyCheck.target = self; needsKeyCheck.action = #selector(fieldChanged(_:))
        fetchButton.target = self; fetchButton.action = #selector(fetchModels(_:))
        testButton.target = self; testButton.action = #selector(test(_:))
        defaultButton.target = self; defaultButton.action = #selector(makeDefault(_:))
        forgetKeyButton.target = self; forgetKeyButton.action = #selector(forgetKey(_:))

        headersView.isRichText = false
        headersView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        headersView.isAutomaticQuoteSubstitutionEnabled = false
        headersView.delegate = self
        let headersScroll = NSScrollView()
        headersScroll.documentView = headersView
        headersScroll.hasVerticalScroller = true
        headersScroll.borderType = .bezelBorder
        headersView.autoresizingMask = [.width]
        NSLayoutConstraint.activate([
            headersScroll.heightAnchor.constraint(equalToConstant: 54),
            headersScroll.widthAnchor.constraint(equalToConstant: 400),
            modelBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.isSelectable = true

        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        let modelRow = NSStackView(views: [modelBox, fetchButton])
        let buttons = NSStackView(views: [testButton, defaultButton, forgetKeyButton])
        let headersHelp = NSTextField(wrappingLabelWithString: "One “Header: value” per line, e.g. HTTP-Referer for OpenRouter or api-key for Azure.")
        headersHelp.preferredMaxLayoutWidth = 400
        statusLabel.preferredMaxLayoutWidth = 400
        headersHelp.font = .systemFont(ofSize: 10)
        headersHelp.textColor = .secondaryLabelColor
        detail.addRow(with: [label("Name:"), nameField])
        detail.addRow(with: [label("API format:"), formatPopup])
        detail.addRow(with: [label("Base URL:"), baseURLField])
        detail.addRow(with: [label("Model:"), modelRow])
        detail.addRow(with: [NSGridCell.emptyContentView, needsKeyCheck])
        detail.addRow(with: [label("API key:"), keyField])
        detail.addRow(with: [label("Extra headers:"), headersScroll])
        detail.addRow(with: [NSGridCell.emptyContentView, headersHelp])
        detail.addRow(with: [NSGridCell.emptyContentView, buttons])
        detail.addRow(with: [NSGridCell.emptyContentView, statusLabel])
        detail.column(at: 0).xPlacement = .trailing
        detail.rowAlignment = .firstBaseline
        detail.rowSpacing = 8
        detail.columnSpacing = 8
        detail.column(at: 1).width = 400
        detail.setContentHuggingPriority(.required, for: .vertical)

        let split = NSStackView(views: [left, detail])
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 20
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            split.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            split.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            left.bottomAnchor.constraint(equalTo: split.bottomAnchor),
        ])
    }

    private func load() {
        let list = AIStore.list
        providers = list.providers
        defaultID = list.defaultProvider?.id
        table.reloadData()
        if !providers.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        showSelection()
    }

    private func persist() {
        AIStore.list = AIProviderList(providers: providers, defaultID: defaultID)
    }

    private func showSelection() {
        let p = selected
        editingID = p?.id
        for v in [nameField, formatPopup, baseURLField, modelBox, fetchButton, needsKeyCheck, keyField, testButton, defaultButton, forgetKeyButton] as [NSControl] {
            v.isEnabled = p != nil
        }
        headersView.isEditable = p != nil
        addRemove.setEnabled(p != nil, forSegment: 1)
        statusLabel.stringValue = p == nil ? "Click + to add a hosted provider or a local model server." : ""
        guard let p else {
            for f in [nameField, baseURLField, keyField] { f.stringValue = "" }
            modelBox.stringValue = ""
            headersView.string = ""
            return
        }
        nameField.stringValue = p.name
        formatPopup.selectItem(withTitle: p.format.displayName)
        baseURLField.stringValue = p.baseURL
        modelBox.stringValue = p.model
        needsKeyCheck.state = p.needsKey ? .on : .off
        keyField.isEnabled = p.needsKey
        keyField.stringValue = ""
        let saved = p.needsKey && Keychain.has(p.id)
        keyField.placeholderString = saved ? "Saved in Keychain — type a new key to replace it" : "Paste your API key — stored in your Keychain"
        forgetKeyButton.isEnabled = saved
        headersView.string = p.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        defaultButton.isEnabled = p.id != defaultID
    }

    /// Copies the form back into the selected provider.
    private func commit() {
        guard let id = editingID, let i = providers.firstIndex(where: { $0.id == id }) else { return }
        var p = providers[i]
        p.name = nameField.stringValue.isEmpty ? "Untitled" : nameField.stringValue
        if let raw = formatPopup.selectedItem?.representedObject as? String, let f = AIWireFormat(rawValue: raw) { p.format = f }
        p.baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)
        p.model = modelBox.stringValue.trimmingCharacters(in: .whitespaces)
        p.needsKey = needsKeyCheck.state == .on
        var headers: [String: String] = [:]
        for line in headersView.string.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces), v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { headers[k] = v }
        }
        p.headers = headers
        guard p != providers[i] else { return }
        providers[i] = p
        persist()
        table.reloadData(forRowIndexes: [i], columnIndexes: [0])
    }

    /// Hosted APIs answer a keyless request with misleading errors (Gemini says 404), so stop early.
    private func hasKeyIfNeeded(_ p: AIProvider) -> Bool {
        guard !AIStore.hasKey(p) else { return true }
        statusLabel.stringValue = "Enter the API key for \(p.name) first. If this is a local server that doesn’t use keys, untick “Requires an API key”."
        window?.makeFirstResponder(keyField)
        return false
    }

    /// Saves a newly typed key; an empty field means "keep the saved one".
    private func saveKey() {
        guard let id = editingID else { return }
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.set(key, for: id)
        keyField.stringValue = ""
        keyField.placeholderString = "Saved in Keychain — type a new key to replace it"
        forgetKeyButton.isEnabled = true
    }

    @objc private func forgetKey(_ sender: Any?) {
        guard let id = editingID else { return }
        Keychain.delete(id)
        keyField.stringValue = ""
        keyField.placeholderString = "Paste your API key — stored in your Keychain"
        forgetKeyButton.isEnabled = false
        statusLabel.stringValue = "Key removed from your Keychain."
    }

    // MARK: Actions

    @objc private func addOrRemove(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 { removeSelected(); return }
        let menu = NSMenu()
        for (i, preset) in AIProvider.presets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(addPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            menu.addItem(item)
            if preset.name == "Fireworks" { menu.addItem(.separator()) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func addPreset(_ sender: NSMenuItem) {
        var p = AIProvider.presets[sender.tag]
        p.id = UUID().uuidString
        providers.append(p)
        if defaultID == nil { defaultID = p.id }
        persist()
        table.reloadData()
        table.selectRowIndexes([providers.count - 1], byExtendingSelection: false)
        window?.makeFirstResponder(p.needsKey ? keyField : modelBox)
        if p.model.isEmpty && !p.needsKey { fetchModels(nil) }
    }

    private func removeSelected() {
        guard let p = selected else { return }
        let a = NSAlert()
        a.messageText = "Remove “\(p.name)”?"
        a.informativeText = "Its API key is also removed from your Keychain."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Keychain.delete(p.id)
        providers.removeAll { $0.id == p.id }
        if defaultID == p.id { defaultID = providers.first?.id }
        persist()
        table.reloadData()
        if !providers.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        showSelection()
    }

    @objc private func fieldChanged(_ sender: Any?) {
        commit()
        keyField.isEnabled = needsKeyCheck.state == .on
    }

    @objc private func makeDefault(_ sender: Any?) {
        guard let p = selected else { return }
        defaultID = p.id
        persist()
        table.reloadData()
        showSelection()
    }

    @objc private func fetchModels(_ sender: Any?) {
        commit(); saveKey()
        guard let p = selected, hasKeyIfNeeded(p) else { return }
        statusLabel.stringValue = "Fetching models from \(p.baseURL)…"
        work?.cancel()
        work = Task { @MainActor in
            do {
                let ids = try await AIClient.listModels(p, apiKey: AIStore.key(for: p))
                modelBox.removeAllItems()
                modelBox.addItems(withObjectValues: ids)
                statusLabel.stringValue = ids.isEmpty ? "The server listed no models; type the model name." : "\(ids.count) models available."
                if modelBox.stringValue.isEmpty, let first = ids.first { modelBox.stringValue = first; commit() }
            } catch is CancellationError {
            } catch {
                statusLabel.stringValue = "Couldn’t list models: \(error.localizedDescription)"
            }
        }
    }

    @objc private func test(_ sender: Any?) {
        commit(); saveKey()
        guard let p = selected, hasKeyIfNeeded(p) else { return }
        statusLabel.stringValue = "Asking \(p.model.isEmpty ? p.name : p.model)…"
        let start = Date()
        work?.cancel()
        work = Task { @MainActor in
            do {
                let reply = try await AIClient.complete(p, apiKey: AIStore.key(for: p),
                    AIRequest(messages: [AIMessage(.user, "Reply with the single word: ready")], maxTokens: 1024))
                let secs = String(format: "%.1f", Date().timeIntervalSince(start))
                statusLabel.stringValue = "✓ Works (\(secs)s): “\(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))”"
            } catch is CancellationError {
            } catch {
                statusLabel.stringValue = "✗ \(error.localizedDescription)"
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { providers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = providers[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: p.name + (p.id == defaultID ? "  ✓" : ""))
        let sub = NSTextField(labelWithString: p.model.isEmpty ? "no model" : p.model)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [title, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 36 }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }

    // MARK: Field editing

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) !== keyField { commit() }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === keyField { saveKey() } else { commit() }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.commit() }
    }

    func textDidChange(_ notification: Notification) { commit() }
}
