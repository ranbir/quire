import AppKit
import QuireCore

/// A project: a saved list of folders and files plus the documents that were
/// open in it. Stored as JSON in a `.quireproject` file.
@objc(QuireProjectDocument)
final class ProjectDocument: NSDocument {
    struct Model: Codable {
        struct Item: Codable {
            var path: String
            var relative: String?
        }
        var items: [Item]
        var openDocuments: [Item]?
        var current: Item?
    }

    private(set) var items: [URL] = []
    private(set) var savedOpenDocuments: [URL] = []
    private(set) var savedCurrent: URL?

    override init() {
        super.init()
        fileType = DocumentController.projectType
    }

    convenience init(items: [URL]) {
        self.init()
        self.items = items
    }

    override class var autosavesInPlace: Bool { false }
    override class var readableTypes: [String] { [DocumentController.projectType] }
    override class var writableTypes: [String] { [DocumentController.projectType] }

    var windowController: ProjectWindowController? { windowControllers.first as? ProjectWindowController }

    override func makeWindowControllers() {
        addWindowController(ProjectWindowController(project: self))
    }

    override var displayName: String! {
        get {
            if fileURL == nil, items.count == 1 { return items[0].lastPathComponent }
            return fileURL.map { $0.deletingPathExtension().lastPathComponent } ?? super.displayName
        }
        set { super.displayName = newValue }
    }

    // MARK: Persistence

    private func resolve(_ item: Model.Item) -> URL {
        if let rel = item.relative, let base = fileURL?.deletingLastPathComponent() {
            let url = base.appendingPathComponent(rel).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: item.path)
    }

    private func item(for url: URL, relativeTo base: URL?) -> Model.Item {
        var rel: String?
        if let base {
            let b = base.standardizedFileURL.pathComponents, u = url.standardizedFileURL.pathComponents
            var common = 0
            while common < min(b.count, u.count), b[common] == u[common] { common += 1 }
            if common > 1 {
                rel = (Array(repeating: "..", count: b.count - common) + u[common...]).joined(separator: "/")
            }
        }
        return Model.Item(path: url.path, relative: rel)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let model = try JSONDecoder().decode(Model.self, from: data)
        items = model.items.map(resolve)
        savedOpenDocuments = (model.openDocuments ?? []).map(resolve)
        savedCurrent = model.current.map(resolve)
    }

    func encodedModel(for url: URL?) throws -> Data {
        let base = url?.deletingLastPathComponent()
        let open = windowController?.documents.compactMap(\.fileURL) ?? savedOpenDocuments
        let current = windowController?.currentDocument?.fileURL ?? savedCurrent
        let model = Model(items: items.map { item(for: $0, relativeTo: base) },
                          openDocuments: open.map { item(for: $0, relativeTo: base) },
                          current: current.map { item(for: $0, relativeTo: base) })
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(model)
    }

    override func data(ofType typeName: String) throws -> Data {
        try encodedModel(for: fileURL)
    }

    override func write(to url: URL, ofType typeName: String) throws {
        try encodedModel(for: url).write(to: url, options: .atomic)
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowsOtherFileTypes = false
        savePanel.nameFieldStringValue = "\(displayName ?? "Untitled").quireproject"
        return true
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? { "quireproject" }

    // MARK: Items

    func add(_ urls: [URL]) {
        let new = urls.map(\.standardizedFileURL).filter { u in !items.contains { $0.standardizedFileURL == u } }
        guard !new.isEmpty else { return }
        items += new
        updateChangeCount(.changeDone)
        windowController?.reloadItems()
    }

    func remove(_ url: URL) {
        items.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        updateChangeCount(.changeDone)
        windowController?.reloadItems()
    }
}

/// Sidebar section header.
final class ProjectSection: NSObject {
    let title: String
    init(_ title: String) { self.title = title }
}

/// Project window: sidebar of open documents and project items, plus an
/// embedded editor showing the selected document.
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                     NSMenuDelegate, EditorHost {
    private static let registry = NSHashTable<ProjectWindowController>.weakObjects()

    static func hosting(_ doc: Document) -> ProjectWindowController? {
        registry.allObjects.first { $0.documents.contains { $0 === doc } }
    }

    private(set) var documents: [Document] = []
    private(set) var currentDocument: Document?
    var activeEditor: EditorViewController? { currentDocument?.editor }
    private var project: ProjectDocument? { document as? ProjectDocument }

    private let outline = NSOutlineView()
    var sidebarOutline: NSOutlineView { outline }
    private let openSection = ProjectSection("Open Documents")
    private let itemsSection = ProjectSection("Project")
    private var roots: [FileNode] = []
    private let contentController = NSViewController()
    private let placeholder = NSTextField(labelWithString: "Choose a file in the sidebar, or drag files and folders there to add them to the project.")
    private var timer: Timer?
    private var dirtySnapshot: [ObjectIdentifier: Bool] = [:]
    private var closeConfirmed = false
    private var closeContinuation: ((Bool) -> Void)?

    init(project: ProjectDocument) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.minSize = NSSize(width: 600, height: 300)
        w.tabbingMode = .disallowed
        super.init(window: w)
        w.delegate = self
        Self.registry.add(self)
        buildUI()
        roots = project.items.map(FileNode.init)
        outline.reloadData()
        outline.expandItem(openSection)
        outline.expandItem(itemsSection)
        if roots.count == 1, roots[0].isDirectory { outline.expandItem(roots[0]) }
        // The split view controller shrinks the window to its minimum; restore a useful size.
        if !w.setFrameUsingName("QuireProjectWindow") {
            w.setContentSize(NSSize(width: 1180, height: 760))
            w.center()
        }
        w.setFrameAutosaveName("QuireProjectWindow")

        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.refreshDirtyState() }

        // Reopen the documents saved with the project.
        let toOpen = project.savedOpenDocuments.filter { FileManager.default.fileExists(atPath: $0.path) }
        let current = project.savedCurrent
        for url in toOpen { openFile(url, makeCurrent: url == current || (current == nil && url == toOpen.last)) }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    // MARK: UI

    private func buildUI() {
        guard let window else { return }
        let split = NSSplitViewController()

        // Sidebar
        let sidebar = NSViewController()
        sidebar.view = NSView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        func barButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.isBordered = false
            b.toolTip = tip
            return b
        }
        let bar = NSStackView(views: [barButton("plus", "Add Files or Folders to Project…", #selector(addItems(_:))),
                                      barButton("minus", "Remove Selected Item from Project", #selector(removeSelectedItem(_:))),
                                      barButton("arrow.clockwise", "Refresh File List", #selector(refreshItems(_:)))])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view.addSubview(scroll)
        sidebar.view.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sidebar.view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            bar.bottomAnchor.constraint(equalTo: sidebar.view.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Content
        contentController.view = NSView()
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        contentController.view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: contentController.view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentController.view.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 180
        sideItem.maximumThickness = 480
        sideItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 320
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "QuireProjectSplit"
        window.contentViewController = split
    }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        guard let current = currentDocument else { return displayName }
        return "\(displayName) — \(current.displayName ?? "")"
    }

    // MARK: Documents

    func openFile(_ url: URL, makeCurrent: Bool = true) {
        if let d = documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            if makeCurrent { show(d) }
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { [weak self] doc, _, error in
            guard let self else { return }
            if let error { self.presentError(error); return }
            guard let d = doc as? Document else {
                // e.g. a nested .quireproject
                doc?.makeWindowControllers(); doc?.showWindows(); return
            }
            if !d.windowControllers.isEmpty || (Self.hosting(d).map { $0 !== self } ?? false) {
                d.editor.reveal()   // already shown elsewhere
                return
            }
            self.attach(d, makeCurrent: makeCurrent)
        }
    }

    func attach(_ d: Document, makeCurrent: Bool = true) {
        if !documents.contains(where: { $0 === d }) { documents.append(d) }
        outline.reloadItem(openSection, reloadChildren: true)
        if makeCurrent || currentDocument == nil { show(d) }
    }

    func show(_ d: Document) {
        if !documents.contains(where: { $0 === d }) { attach(d); return }
        showWindow(nil)
        if currentDocument !== d {
            if let cur = currentDocument {
                cur.editor.view.removeFromSuperview()
                cur.editor.removeFromParent()
            }
            currentDocument = d
            let ed = d.editor
            ed.removeFromParent()
            ed.view.removeFromSuperview()
            contentController.addChild(ed)
            ed.view.frame = contentController.view.bounds
            ed.view.autoresizingMask = [.width, .height]
            contentController.view.addSubview(ed.view)
            // Make sure the editor sits in the responder chain so Save etc. reach its document.
            if ed.view.nextResponder !== ed {
                ed.nextResponder = ed.view.nextResponder
                ed.view.nextResponder = ed
            }
            placeholder.isHidden = true
            ed.refreshGit(reloadHead: true)
        }
        window?.makeFirstResponder(d.editor.textView)
        synchronizeWindowTitleWithDocumentName()
        if let url = d.fileURL { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        let row = outline.row(forItem: d)
        if row >= 0, outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        refreshDirtyState()
    }

    func detach(_ d: Document) {
        documents.removeAll { $0 === d }
        if currentDocument === d {
            d.editor.view.removeFromSuperview()
            d.editor.removeFromParent()
            currentDocument = nil
            if let next = documents.last { show(next) } else { placeholder.isHidden = false; synchronizeWindowTitleWithDocumentName() }
        }
        outline.reloadItem(openSection, reloadChildren: true)
    }

    /// Asks to save if needed, then closes the document.
    func requestClose(_ d: Document, completion: @escaping (Bool) -> Void) {
        closeContinuation = completion
        d.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let c = closeContinuation
        closeContinuation = nil
        if shouldClose, let d = doc as? Document {
            detach(d)
            d.close()
        }
        c?(shouldClose)
    }

    @objc func closeEditorDocument(_ sender: Any?) {
        guard let d = (sender as? NSMenuItem)?.representedObject as? Document ?? currentDocument else { NSSound.beep(); return }
        requestClose(d) { _ in }
    }

    private func closeAll(_ completion: @escaping (Bool) -> Void) {
        if let dirty = documents.first(where: { $0.isDocumentEdited }) {
            requestClose(dirty) { ok in ok ? self.closeAll(completion) : completion(false) }
            return
        }
        let all = documents
        all.forEach { detach($0); $0.close() }
        completion(true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed || documents.isEmpty { return true }
        // Remember open documents in a saved project before closing them.
        if let project, let url = project.fileURL, !project.isDocumentEdited {
            try? project.encodedModel(for: url).write(to: url, options: .atomic)
            project.fileModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        closeAll { ok in
            guard ok else { return }
            self.closeConfirmed = true
            self.window?.performClose(nil)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        Self.registry.remove(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let ed = activeEditor { window?.makeFirstResponder(ed.textView); ed.refreshGit(reloadHead: true) }
    }

    private func refreshDirtyState() {
        var snapshot: [ObjectIdentifier: Bool] = [:]
        for d in documents { snapshot[ObjectIdentifier(d)] = d.isDocumentEdited }
        if snapshot != dirtySnapshot {
            dirtySnapshot = snapshot
            for d in documents { outline.reloadItem(d) }
        }
        window?.isDocumentEdited = (currentDocument?.isDocumentEdited ?? false) || (project?.isDocumentEdited ?? false)
    }

    // MARK: Items

    func reloadItems() {
        roots = (project?.items ?? []).map(FileNode.init)
        outline.reloadItem(itemsSection, reloadChildren: true)
        outline.expandItem(itemsSection)
    }

    @objc func addItems(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Project"
        guard let w = window else { return }
        panel.beginSheetModal(for: w) { [weak self] r in
            if r == .OK { self?.project?.add(panel.urls) }
        }
    }

    @objc func removeSelectedItem(_ sender: Any?) {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0 else { NSSound.beep(); return }
        let item = outline.item(atRow: row)
        if let node = item as? FileNode, roots.contains(where: { $0 === node }) {
            project?.remove(node.url)
        } else if let d = item as? Document {
            requestClose(d) { _ in }
        } else {
            NSSound.beep()
        }
    }

    @objc func refreshItems(_ sender: Any?) {
        roots.forEach { $0.reloadRecursively() }
        outline.reloadItem(itemsSection, reloadChildren: true)
    }

    private var targetItem: Any? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) : nil
    }

    @objc private func doubleClicked(_ sender: Any?) {
        switch targetItem {
        case let node as FileNode where node.isDirectory:
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        case let node as FileNode:
            openFile(node.url)
        case let d as Document:
            show(d)
        default: break
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        switch targetItem {
        case let node as FileNode:
            if !node.isDirectory {
                add("Open", #selector(doubleClicked(_:)))
                add("Open in Separate Window", #selector(openInSeparateWindow(_:)))
            }
            add("Search in \(node.isDirectory ? "Folder" : "Enclosing Folder")…", #selector(searchHere(_:)))
            add("Reveal in Finder", #selector(revealInFinder(_:)))
            if roots.contains(where: { $0 === node }) {
                menu.addItem(.separator())
                add("Remove from Project", #selector(removeSelectedItem(_:)))
            }
        case let d as Document:
            add("Close Document", #selector(closeClickedDocument(_:)))
            if d.fileURL != nil { add("Reveal in Finder", #selector(revealInFinder(_:))) }
        default:
            add("Add Files or Folders…", #selector(addItems(_:)))
        }
    }

    @objc private func openInSeparateWindow(_ sender: Any?) {
        guard let node = targetItem as? FileNode else { return }
        (NSDocumentController.shared as? DocumentController)?.open(node.url)
    }

    @objc private func closeClickedDocument(_ sender: Any?) {
        if let d = targetItem as? Document { requestClose(d) { _ in } }
    }

    @objc private func searchHere(_ sender: Any?) {
        guard let node = targetItem as? FileNode else { return }
        FindPanelController.shared.folderField.stringValue = (node.isDirectory ? node.url : node.url.deletingLastPathComponent()).path
        FindPanelController.shared.show(withSelectionFrom: nil)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        let url = (targetItem as? FileNode)?.url ?? (targetItem as? Document)?.fileURL
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: Outline data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return 2
        case let s as ProjectSection: return s === openSection ? documents.count : roots.count
        case let n as FileNode: return n.children.count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil: return index == 0 ? openSection : itemsSection
        case let s as ProjectSection: return s === openSection ? documents[index] : roots[index]
        case let n as FileNode: return n.children[index]
        default: return NSNull()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is ProjectSection { return true }
        return (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is ProjectSection }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is ProjectSection) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(label)
        if let s = item as? ProjectSection {
            label.stringValue = s.title
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                         label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = icon
        cell.addSubview(icon)
        switch item {
        case let d as Document:
            label.stringValue = (d.isDocumentEdited ? "• " : "") + (d.fileURL?.lastPathComponent ?? d.displayName ?? "untitled")
            icon.image = d.fileURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            cell.toolTip = d.fileURL?.path
        case let n as FileNode:
            label.stringValue = n.url.lastPathComponent
            icon.image = NSWorkspace.shared.icon(forFile: n.url.path)
            cell.toolTip = n.url.path
        default: break
        }
        icon.image?.size = NSSize(width: 16, height: 16)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Single click opens a file.
        guard outline.selectedRow >= 0 else { return }
        switch outline.item(atRow: outline.selectedRow) {
        case let d as Document: if d !== currentDocument { show(d) }
        case let n as FileNode where !n.isDirectory: openFile(n.url)
        default: break
        }
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        outlineView.setDropItem(itemsSection, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        project?.add(urls)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        ((item as? FileNode)?.url ?? (item as? Document)?.fileURL) as NSURL?
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(closeEditorDocument(_:)) { return currentDocument != nil }
        return true
    }
}
