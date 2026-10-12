import AppKit
import QuireCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let filtersMenu = NSMenu(title: "Text Filters")
    private let clippingsMenu = NSMenu(title: "Clippings")
    private let languageMenu = NSMenu(title: "Language")
    private var moduleErrors: [String] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        moduleErrors = LanguageModulesLibrary.reload()
        NSApp.mainMenu = buildMainMenu()
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TextFilters.ensureFolder()
        ClippingsLibrary.ensureFolder()
        if !moduleErrors.isEmpty {
            alert("Some language modules couldn’t be loaded", moduleErrors.joined(separator: "\n"))
        }
        runDevelopmentHooks()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
               !NSWorkspace.shared.isFilePackage(atPath: url.path) {
                openProject(folder: url)
            } else {
                documentController.open(url)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    private var documentController: DocumentController { NSDocumentController.shared as! DocumentController }

    private var editor: EditorViewController? { NSApp.mainEditor }

    // MARK: Menu construction

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach { m.addItem($0) }
        parent.submenu = m
        return parent
    }

    private func submenu(_ title: String, menu: NSMenu) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.delegate = self
        parent.submenu = menu
        return parent
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let sep = { NSMenuItem.separator() }
        func key(_ code: Int) -> String { String(UnicodeScalar(code)!) }
        let up = key(NSUpArrowFunctionKey), down = key(NSDownArrowFunctionKey)
        let left = key(NSLeftArrowFunctionKey), right = key(NSRightArrowFunctionKey)

        // App
        main.addItem(submenu("Quire", [
            item("About Quire", #selector(showAbout(_:)), target: self),
            sep(),
            item("Open Text Filters Folder", #selector(openFiltersFolder(_:)), target: self),
            item("Open Clippings Folder", #selector(openClippingsFolder(_:)), target: self),
            item("Open Language Modules Folder", #selector(openLanguageModulesFolder(_:)), target: self),
            sep(),
            submenu("Services", []),
            sep(),
            item("Hide Quire", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            sep(),
            item("Quit Quire", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        NSApp.servicesMenu = main.items[0].submenu?.items.first { $0.title == "Services" }?.submenu

        // File
        let recent = submenu("Open Recent", [item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))])
        recent.submenu?.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        main.addItem(submenu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("New Shell Worksheet", #selector(newWorksheet(_:)), "n", [.command, .option], target: self),
            item("New Project", #selector(newProject(_:)), "n", [.command, .shift], target: self),
            item("New from Clipboard", #selector(newFromClipboard(_:)), "n", [.command, .control], target: self),
            sep(),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            item("Open Folder as Project…", #selector(openFolder(_:)), "o", [.command, .shift], target: self),
            item("Open from SFTP Server…", #selector(openFromSFTP(_:)), "o", [.command, .control], target: self),
            recent,
            sep(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
            item("Close Document", #selector(ProjectWindowController.closeEditorDocument(_:)), "w", [.command, .control]),
            item("Save", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
            sep(),
            item("Reveal in Finder", #selector(revealInFinder(_:)), "r", [.command, .option], target: self),
            item("Copy Path", #selector(copyPath(_:)), "c", [.command, .option, .shift], target: self),
            sep(),
            item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]),
            item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
        ]))

        // Edit
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            sep(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            sep(),
            item("Complete", #selector(NSTextView.complete(_:)), "\u{1b}", [.option]),
            sep(),
            item("Duplicate Line", #selector(EditorTextView.duplicateLine(_:)), "d", [.command, .shift]),
            item("Delete Line", #selector(EditorTextView.deleteLine(_:)), "k", [.control, .shift]),
            item("Move Line Up", #selector(EditorTextView.moveLineUp(_:)), up, [.command, .control]),
            item("Move Line Down", #selector(EditorTextView.moveLineDown(_:)), down, [.command, .control]),
            sep(),
            item("Font…", #selector(NSFontManager.orderFrontFontPanel(_:)), "t", [.command, .shift]),
        ]))

        // Text
        filtersMenu.delegate = self
        let filters = NSMenuItem(title: "Text Filters", action: nil, keyEquivalent: "")
        filters.submenu = filtersMenu
        main.addItem(submenu("Text", [
            item("Shift Left", #selector(EditorTextView.shiftLeft(_:)), "["),
            item("Shift Right", #selector(EditorTextView.shiftRight(_:)), "]"),
            item("Un/Comment Lines", #selector(EditorTextView.toggleComment(_:)), "/"),
            item("Balance", #selector(EditorTextView.balance(_:)), "b"),
            sep(),
            submenu("Change Case", [
                item("UPPER CASE", #selector(EditorTextView.makeUpperCase(_:)), "u", [.command, .control]),
                item("lower case", #selector(EditorTextView.makeLowerCase(_:)), "l", [.command, .control]),
                item("Title Case", #selector(EditorTextView.makeTitleCase(_:))),
                item("Capitalize Words", #selector(EditorTextView.capitalizeWordsCmd(_:))),
                item("Capitalize Lines", #selector(EditorTextView.capitalizeLinesCmd(_:))),
                item("Capitalize Sentences", #selector(EditorTextView.capitalizeSentencesCmd(_:))),
            ]),
            submenu("Sort Lines", [
                item("Ascending", #selector(EditorTextView.sortLinesAscending(_:))),
                item("Descending", #selector(EditorTextView.sortLinesDescending(_:))),
                item("Numeric", #selector(EditorTextView.sortLinesNumeric(_:))),
                item("Case-Sensitive", #selector(EditorTextView.sortLinesCaseSensitive(_:))),
            ]),
            item("Remove Duplicate Lines", #selector(EditorTextView.removeDuplicateLines(_:))),
            item("Reverse Lines", #selector(EditorTextView.reverseLines(_:))),
            item("Process Lines Containing…", #selector(EditorTextView.processLinesContaining(_:))),
            item("Prefix/Suffix Lines…", #selector(EditorTextView.prefixSuffixLines(_:))),
            item("Add Line Numbers", #selector(EditorTextView.addLineNumbers(_:))),
            item("Remove Line Numbers", #selector(EditorTextView.removeLineNumbers(_:))),
            sep(),
            item("Hard Wrap…", #selector(EditorTextView.hardWrap(_:))),
            item("Remove Line Breaks", #selector(EditorTextView.removeLineBreaks(_:))),
            item("Strip Trailing Whitespace", #selector(EditorTextView.stripTrailingWhitespace(_:))),
            item("Zap Gremlins", #selector(EditorTextView.zapGremlins(_:))),
            item("Entab", #selector(EditorTextView.entab(_:))),
            item("Detab", #selector(EditorTextView.detab(_:))),
            item("Straighten Quotes", #selector(EditorTextView.straightenQuotes(_:))),
            item("Educate Quotes", #selector(EditorTextView.educateQuotes(_:))),
            item("Format JSON", #selector(EditorTextView.formatJSON(_:)), "j", [.command, .option]),
            sep(),
            item("Text Statistics", #selector(EditorTextView.showStatistics(_:)), "i", [.command, .option]),
        ]))

        // Shell (#!)
        main.addItem(submenu("#!", [
            item("Run Worksheet Line/Selection", #selector(EditorViewController.runWorksheetCommand(_:)), "\r"),
            item("Stop Running Command", #selector(EditorViewController.stopWorksheetCommand(_:)), "."),
            sep(),
            item("Run Shell Command on Selection…", #selector(runShellCommand(_:)), "|", [.command], target: self),
            filters,
            item("Open Text Filters Folder", #selector(openFiltersFolder(_:)), target: self),
        ]))

        // Clippings (rebuilt per language)
        main.addItem(submenu("Clippings", menu: clippingsMenu))

        // Search
        let find = FindPanelController.shared
        main.addItem(submenu("Search", [
            item("Find…", #selector(showFind(_:)), "f", target: self),
            item("Multi-File Search…", #selector(showMultiFileSearch(_:)), "f", [.command, .shift], target: self),
            sep(),
            item("Find Next", #selector(FindPanelController.findNext(_:)), "g", target: find),
            item("Find Previous", #selector(FindPanelController.findPrevious(_:)), "g", [.command, .shift], target: find),
            item("Find All", #selector(FindPanelController.findAll(_:)), "f", [.command, .option], target: find),
            item("Use Selection for Find", #selector(useSelectionForFind(_:)), "e", target: self),
            item("Use Selection for Replace", #selector(useSelectionForReplace(_:)), "e", [.command, .option], target: self),
            sep(),
            item("Replace", #selector(FindPanelController.replace(_:)), "=", [.command, .option], target: find),
            item("Replace & Find Next", #selector(FindPanelController.replaceAndFind(_:)), "=", target: find),
            item("Replace All", #selector(FindPanelController.replaceAll(_:)), "r", [.command, .option, .shift], target: find),
            sep(),
            item("Go to Line…", #selector(EditorTextView.goToLine(_:)), "j"),
            sep(),
            item("Compare Two Front Documents", #selector(compareFrontDocuments(_:)), "d", [.command, .option], target: self),
            item("Compare with Saved Version", #selector(compareWithSaved(_:)), target: self),
            item("Compare with File…", #selector(compareWithFile(_:)), target: self),
        ]))

        // Git
        main.addItem(submenu("Git", [
            item("Compare with HEAD", #selector(gitShowChanges(_:)), "d", [.command, .control], target: self),
            item("Blame", #selector(gitBlame(_:)), target: self),
            item("File History", #selector(gitFileLog(_:)), target: self),
            sep(),
            item("Repository Status", #selector(gitRepositoryStatus(_:)), target: self),
            item("Repository Diff", #selector(gitRepositoryDiff(_:)), target: self),
            sep(),
            item("Stage File", #selector(gitStageFile(_:)), target: self),
            item("Unstage File", #selector(gitUnstageFile(_:)), target: self),
            item("Discard Changes…", #selector(gitDiscardChanges(_:)), target: self),
            item("Commit…", #selector(gitCommit(_:)), "k", [.command, .option], target: self),
            sep(),
            item("Show Change Markers in Gutter", #selector(toggleGitIntegration(_:)), target: self),
        ]))

        // View
        main.addItem(submenu("View", [
            item("Show Preview", #selector(EditorViewController.showPreview(_:)), "p", [.command, .option]),
            sep(),
            item("Show Line Numbers", #selector(toggleLineNumbers(_:)), target: self),
            item("Soft Wrap Text", #selector(toggleSoftWrap(_:)), "\\", [.command, .option], target: self),
            item("Show Invisibles", #selector(toggleInvisibles(_:)), "i", [.command, .option, .shift], target: self),
            item("Show Page Guide", #selector(togglePageGuide(_:)), target: self),
            item("Highlight Current Line", #selector(toggleCurrentLine(_:)), target: self),
            sep(),
            submenu("Folding", [
                item("Fold Selection", #selector(EditorViewController.foldSelection(_:)), left, [.command, .option]),
                item("Unfold Selection", #selector(EditorViewController.unfoldSelection(_:)), right, [.command, .option]),
                item("Collapse Enclosing Fold", #selector(EditorViewController.collapseEnclosingFold(_:))),
                item("Collapse All Folds", #selector(EditorViewController.collapseAllFolds(_:)), left, [.command, .option, .shift]),
                item("Expand All Folds", #selector(EditorViewController.expandAllFolds(_:)), right, [.command, .option, .shift]),
            ]),
            sep(),
            item("Auto-Expand Tabs", #selector(toggleExpandTabs(_:)), target: self),
            item("Auto-Indent", #selector(toggleAutoIndent(_:)), target: self),
            item("Auto-Complete as You Type", #selector(toggleAutoComplete(_:)), target: self),
            submenu("Tab Width", [2, 3, 4, 8].map { n in
                let i = item("\(n)", #selector(setTabWidth(_:)), target: self); i.tag = n; return i
            }),
            submenu("Page Guide Column", [72, 80, 100, 120].map { n in
                let i = item("\(n)", #selector(setGuideColumn(_:)), target: self); i.tag = n; return i
            }),
            sep(),
            item("Bigger", #selector(fontBigger(_:)), "+", target: self),
            item("Bigger", #selector(fontBigger(_:)), "=", target: self).hiddenAlternate(),
            item("Smaller", #selector(fontSmaller(_:)), "-", target: self),
            item("Actual Size", #selector(fontActual(_:)), "0", target: self),
            sep(),
            submenu("Language", menu: languageMenu),
        ]))

        // Window
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            sep(),
            item("Find Window", #selector(showFind(_:)), "", target: self),
            item("SFTP Browser", #selector(openFromSFTP(_:)), "", target: self),
            sep(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = submenu("Help", [item("Quire Help", #selector(showHelp(_:)), "?", target: self)])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    // MARK: Dynamic menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === filtersMenu { rebuildFiltersMenu(menu) }
        else if menu === clippingsMenu { rebuildClippingsMenu(menu) }
        else if menu === languageMenu { rebuildLanguageMenu(menu) }
    }

    private func rebuildFiltersMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let filters = TextFilters.list()
        for url in filters {
            let i = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(runTextFilter(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = url
            menu.addItem(i)
        }
        if filters.isEmpty { menu.addItem(withTitle: "No filters installed", action: nil, keyEquivalent: "").isEnabled = false }
        menu.addItem(.separator())
        menu.addItem(item("Open Text Filters Folder", #selector(openFiltersFolder(_:)), target: self))
    }

    private func rebuildClippingsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        ClippingsLibrary.ensureFolder()
        let lang = editor?.textView.language.name ?? Languages.plainText.name
        let langDir = ClippingsLibrary.folder.appendingPathComponent(ClippingsLibrary.folderName(for: lang))
        func header(_ s: String) {
            let h = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
        if lang != ClippingsLibrary.universal, FileManager.default.fileExists(atPath: langDir.path) {
            header(lang)
            ClippingsLibrary.addItems(from: langDir, to: menu, action: #selector(insertClippingFromMenu(_:)), target: self)
            menu.addItem(.separator())
        }
        header("Universal")
        ClippingsLibrary.addItems(from: ClippingsLibrary.folder.appendingPathComponent(ClippingsLibrary.universal),
                                  to: menu, action: #selector(insertClippingFromMenu(_:)), target: self)
        menu.addItem(.separator())
        menu.addItem(item("Next Placeholder", #selector(EditorTextView.selectNextPlaceholder(_:)), "/", [.control]))
        menu.addItem(item("Previous Placeholder", #selector(EditorTextView.selectPreviousPlaceholder(_:)), "/", [.control, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("New \(lang) Clipping…", #selector(newClipping(_:)), target: self))
        menu.addItem(item("Open Clippings Folder", #selector(openClippingsFolder(_:)), target: self))
    }

    private func rebuildLanguageMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for name in Languages.names {
            menu.addItem(item(name, #selector(EditorViewController.setLanguageFromMenu(_:)), "", []))
        }
        menu.addItem(.separator())
        menu.addItem(item("Export Current Language as Module…", #selector(exportLanguageModule(_:)), target: self))
        menu.addItem(item("Reload Language Modules", #selector(reloadLanguageModules(_:)), target: self))
        menu.addItem(item("Open Language Modules Folder", #selector(openLanguageModulesFolder(_:)), target: self))
    }

    // MARK: Clippings

    @objc func insertClippingFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let ed = editor,
              let template = try? String(contentsOf: url, encoding: .utf8) else { NSSound.beep(); return }
        ed.textView.insertClipping(template, fileName: ed.doc?.fileURL?.lastPathComponent ?? ed.displayName)
    }

    @objc func newClipping(_ sender: Any?) {
        guard let ed = editor else { NSSound.beep(); return }
        let lang = ed.textView.language
        let dir = ClippingsLibrary.folder.appendingPathComponent(ClippingsLibrary.folderName(for: lang.name))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sel = (ed.textView.string as NSString).substring(with: ed.textView.selectedRange())
        guard let name = ed.textView.prompt("New Clipping", message: "Name for the new \(lang.name) clipping (the selected text becomes its contents):", defaultValue: ""),
              !name.isEmpty else { return }
        let ext = lang.extensions.first ?? "txt"
        let url = dir.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "-")).\(ext)")
        do {
            try (sel.isEmpty ? "#SELECTION##INSERTION#" : sel).write(to: url, atomically: true, encoding: .utf8)
            documentController.open(url)
        } catch { NSApp.presentError(error) }
    }

    @objc func openClippingsFolder(_ sender: Any?) {
        ClippingsLibrary.ensureFolder()
        NSWorkspace.shared.open(ClippingsLibrary.folder)
    }

    // MARK: Language modules

    @objc func reloadLanguageModules(_ sender: Any?) {
        let errors = LanguageModulesLibrary.reload()
        if errors.isEmpty {
            alert("Language modules reloaded", "\(Languages.modules.count) module\(Languages.modules.count == 1 ? "" : "s") loaded from \(LanguageModulesLibrary.folder.path).")
        } else {
            alert("Some language modules couldn’t be loaded", errors.joined(separator: "\n"))
        }
    }

    @objc func openLanguageModulesFolder(_ sender: Any?) {
        LanguageModulesLibrary.ensureFolder()
        NSWorkspace.shared.open(LanguageModulesLibrary.folder)
    }

    @objc func exportLanguageModule(_ sender: Any?) {
        guard let lang = editor?.textView.language, lang.name != Languages.plainText.name else {
            alert("No language to export", "Choose a language for the front document first."); return
        }
        LanguageModulesLibrary.ensureFolder()
        var url = LanguageModulesLibrary.folder.appendingPathComponent("\(ClippingsLibrary.folderName(for: lang.name)).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = LanguageModulesLibrary.folder.appendingPathComponent("\(ClippingsLibrary.folderName(for: lang.name)) \(n).json"); n += 1
        }
        do {
            try LanguageModule(language: lang).encoded().write(to: url)
            documentController.open(url)
        } catch { NSApp.presentError(error) }
    }

    // MARK: Text filters & shell

    private func runAsync(on tv: EditorTextView, label: String, _ work: @escaping (String) throws -> String) {
        let sel = tv.selectedRange()
        let range = sel.length > 0 ? sel : NSRange(location: 0, length: (tv.string as NSString).length)
        let input = (tv.string as NSString).substring(with: range)
        let before = tv.string
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(input) }
            DispatchQueue.main.async {
                switch result {
                case .success(let output):
                    guard tv.string == before else { NSSound.beep(); return }   // text changed meanwhile
                    tv.replace(range, with: output, select: sel.length > 0)
                case .failure(let error):
                    let a = NSAlert()
                    a.messageText = "“\(label)” failed"
                    a.informativeText = error.localizedDescription
                    if let w = tv.window { a.beginSheetModal(for: w) } else { a.runModal() }
                }
            }
        }
    }

    @objc func runTextFilter(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let tv = editor?.textView else { NSSound.beep(); return }
        runAsync(on: tv, label: sender.title) { try TextFilters.run(filter: url, input: $0) }
    }

    @objc func runShellCommand(_ sender: Any?) {
        guard let tv = editor?.textView else { NSSound.beep(); return }
        let last = UserDefaults.standard.string(forKey: "lastShellCommand") ?? "sort"
        guard let cmd = tv.prompt("Run Shell Command", message: "The selection (or whole document) is piped to this command via zsh; its output replaces it.", defaultValue: last),
              !cmd.isEmpty else { return }
        UserDefaults.standard.set(cmd, forKey: "lastShellCommand")
        runAsync(on: tv, label: cmd) { try TextFilters.run(command: cmd, input: $0) }
    }

    @objc func openFiltersFolder(_ sender: Any?) {
        TextFilters.ensureFolder()
        NSWorkspace.shared.open(TextFilters.folder)
    }

    // MARK: File actions

    @objc func newWorksheet(_ sender: Any?) {
        guard let doc = try? documentController.openUntitledDocumentAndDisplay(true) as? Document else { NSSound.beep(); return }
        doc.isWorksheet = true
        doc.language = Languages.named("Shell Script")
        doc.load(text: """
        # Quire Shell Worksheet
        # Put the caret on a line (or select several) and press ⌘↩ to run it.
        # Output is inserted below. The shell keeps its directory and variables
        # between commands; ⌘. stops a long-running command.

        pwd
        ls -la

        """)
        doc.editor.textView.setSelectedRange(NSRange(location: (doc.text as NSString).range(of: "pwd").location, length: 0))
    }

    @objc func newProject(_ sender: Any?) {
        showProject(ProjectDocument(items: []))
    }

    func openProject(folder: URL) {
        if let existing = NSDocumentController.shared.documents.first(where: { ($0 as? ProjectDocument)?.items == [folder] }) {
            existing.showWindows(); return
        }
        showProject(ProjectDocument(items: [folder]))
        NSDocumentController.shared.noteNewRecentDocumentURL(folder)
    }

    private func showProject(_ p: ProjectDocument) {
        NSDocumentController.shared.addDocument(p)
        p.makeWindowControllers()
        p.showWindows()
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open as Project"
        guard panel.runModal() == .OK else { return }
        if panel.urls.count == 1 { openProject(folder: panel.urls[0]) }
        else { showProject(ProjectDocument(items: panel.urls)) }
    }

    @objc func openFromSFTP(_ sender: Any?) {
        RemoteBrowserWindowController.shared.showBrowser()
    }

    @objc func newFromClipboard(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string),
              let doc = try? documentController.openUntitledDocumentAndDisplay(true) as? Document else { NSSound.beep(); return }
        let ed = doc.editor
        ed.textView.replace(NSRange(location: 0, length: 0), with: TextCodec.normalizeLineEndings(s), select: false)
        ed.setLanguage(Languages.detect(filename: nil, firstLine: s.split(separator: "\n").first.map(String.init)))
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = editor?.doc?.fileURL else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func copyPath(_ sender: Any?) {
        guard let doc = editor?.doc else { NSSound.beep(); return }
        let path = doc.remote?.display ?? doc.fileURL?.path
        guard let path else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: Search actions

    @objc func showFind(_ sender: Any?) { FindPanelController.shared.show(withSelectionFrom: editor?.textView) }
    @objc func showMultiFileSearch(_ sender: Any?) { FindPanelController.shared.showMultiFile() }

    @objc func useSelectionForFind(_ sender: Any?) {
        guard let tv = editor?.textView else { return }
        FindPanelController.shared.useSelectionForFind(tv)
    }

    @objc func useSelectionForReplace(_ sender: Any?) {
        guard let tv = editor?.textView else { return }
        FindPanelController.shared.useSelectionForReplace(tv)
    }

    private func displayName(_ ed: EditorViewController) -> String {
        ed.doc?.fileURL?.lastPathComponent ?? ed.displayName
    }

    @objc func compareFrontDocuments(_ sender: Any?) {
        var editors: [EditorViewController] = NSApp.orderedWindows.compactMap { ($0.windowController as? EditorHost)?.activeEditor }
        for case let d as Document in NSDocumentController.shared.documents where !editors.contains(where: { $0 === d.editor }) {
            editors.append(d.editor)
        }
        guard editors.count >= 2 else { compareWithFile(sender); return }
        let new = editors[0], old = editors[1]
        DiffWindowController.show(oldText: old.textView.string, newText: new.textView.string,
                                  oldName: displayName(old), newName: displayName(new))
    }

    @objc func compareWithSaved(_ sender: Any?) {
        guard let ed = editor, let url = ed.doc?.fileURL, let data = try? Data(contentsOf: url) else { NSSound.beep(); return }
        DiffWindowController.show(oldText: TextCodec.decode(data).text, newText: ed.textView.string,
                                  oldName: "\(url.lastPathComponent) (saved)", newName: "\(url.lastPathComponent) (current)")
    }

    @objc func compareWithFile(_ sender: Any?) {
        guard let ed = editor else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.message = "Choose a file to compare with “\(displayName(ed))”"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        DiffWindowController.show(oldText: TextCodec.decode(data).text, newText: ed.textView.string,
                                  oldName: url.lastPathComponent, newName: displayName(ed))
    }

    // MARK: View preferences

    @objc func toggleLineNumbers(_ s: Any?) { Prefs.showLineNumbers.toggle() }
    @objc func toggleSoftWrap(_ s: Any?) { Prefs.softWrap.toggle() }
    @objc func toggleInvisibles(_ s: Any?) { Prefs.showInvisibles.toggle() }
    @objc func togglePageGuide(_ s: Any?) { Prefs.showPageGuide.toggle() }
    @objc func toggleCurrentLine(_ s: Any?) { Prefs.highlightCurrentLine.toggle() }
    @objc func toggleExpandTabs(_ s: Any?) { Prefs.expandTabs.toggle() }
    @objc func toggleAutoIndent(_ s: Any?) { Prefs.autoIndent.toggle() }
    @objc func toggleAutoComplete(_ s: Any?) { Prefs.autoComplete.toggle() }
    @objc func toggleGitIntegration(_ s: Any?) {
        Prefs.gitIntegration.toggle()
        for case let d as Document in NSDocumentController.shared.documents { d.editor.refreshGit(reloadHead: true) }
    }
    @objc func setTabWidth(_ s: NSMenuItem) { Prefs.tabWidth = s.tag }
    @objc func setGuideColumn(_ s: NSMenuItem) { Prefs.pageGuideColumn = s.tag }
    @objc func fontBigger(_ s: Any?) { Prefs.fontSize += 1 }
    @objc func fontSmaller(_ s: Any?) { Prefs.fontSize -= 1 }
    @objc func fontActual(_ s: Any?) {
        UserDefaults.standard.removeObject(forKey: "fontName")
        Prefs.fontSize = 13
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let on: Bool?
        switch item.action {
        case #selector(toggleLineNumbers(_:)): on = Prefs.showLineNumbers
        case #selector(toggleSoftWrap(_:)): on = Prefs.softWrap
        case #selector(toggleInvisibles(_:)): on = Prefs.showInvisibles
        case #selector(togglePageGuide(_:)): on = Prefs.showPageGuide
        case #selector(toggleCurrentLine(_:)): on = Prefs.highlightCurrentLine
        case #selector(toggleExpandTabs(_:)): on = Prefs.expandTabs
        case #selector(toggleAutoIndent(_:)): on = Prefs.autoIndent
        case #selector(toggleAutoComplete(_:)): on = Prefs.autoComplete
        case #selector(toggleGitIntegration(_:)): on = Prefs.gitIntegration
        case #selector(setTabWidth(_:)): on = Prefs.tabWidth == item.tag
        case #selector(setGuideColumn(_:)): on = Prefs.pageGuideColumn == item.tag
        default: on = nil
        }
        if let on { item.state = on ? .on : .off }
        switch item.action {
        case #selector(revealInFinder(_:)), #selector(compareWithSaved(_:)):
            return editor?.doc?.fileURL != nil
        case #selector(gitShowChanges(_:)), #selector(gitBlame(_:)), #selector(gitFileLog(_:)), #selector(gitRepositoryStatus(_:)),
             #selector(gitRepositoryDiff(_:)), #selector(gitStageFile(_:)), #selector(gitUnstageFile(_:)),
             #selector(gitDiscardChanges(_:)), #selector(gitCommit(_:)):
            return editor?.doc?.fileURL != nil && editor?.doc?.remote == nil
        case #selector(copyPath(_:)):
            return editor?.doc?.fileURL != nil
        case #selector(runTextFilter(_:)), #selector(runShellCommand(_:)), #selector(useSelectionForFind(_:)),
             #selector(useSelectionForReplace(_:)), #selector(compareWithFile(_:)), #selector(compareFrontDocuments(_:)),
             #selector(insertClippingFromMenu(_:)), #selector(newClipping(_:)), #selector(exportLanguageModule(_:)):
            return editor != nil
        default:
            return true
        }
    }

    // MARK: About / help

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "A fast plain-text and code editor for macOS.\n\nDeveloper: Ranbir Mazumdar",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func showHelp(_ sender: Any?) {
        guard let readme = Bundle.main.url(forResource: "README", withExtension: "md") else { NSSound.beep(); return }
        documentController.openDocument(withContentsOf: readme, display: true) { doc, _, _ in
            (doc as? Document)?.editor.showPreview(nil)
        }
    }

    // MARK: Development hooks

    /// QUIRE_SELFTEST=1 runs the AppKit self-test. QUIRE_SNAPSHOT=/path.png renders
    /// every visible window to /path.N.png after running the comma-separated
    /// actions in QUIRE_SNAPSHOT_SHOW (e.g. "project,collapseAll,preview").
    private func runDevelopmentHooks() {
        let env = ProcessInfo.processInfo.environment
        if env["QUIRE_SELFTEST"] != nil { SelfTest.run() }
        if env["QUIRE_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        guard let path = env["QUIRE_SNAPSHOT"] else { return }
        let actions = (env["QUIRE_SNAPSHOT_SHOW"] ?? "").split(separator: ",").map(String.init)
        var delay = 1.0
        for action in actions {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let find = FindPanelController.shared
                let ed = NSApp.activeEditor
                switch action {
                case "find": self.showMultiFileSearch(nil)
                case "search":
                    find.findField.stringValue = env["QUIRE_SNAPSHOT_PATTERN"] ?? "func"
                    self.showMultiFileSearch(nil)
                    find.searchFolder(nil)
                case "diff": self.compareFrontDocuments(nil)
                case "project": if let dir = env["QUIRE_SNAPSHOT_FOLDER"] { self.openProject(folder: URL(fileURLWithPath: dir)) }
                case "projectFile":
                    if let f = env["QUIRE_SNAPSHOT_FILE"] {
                        NSApp.windows.lazy.compactMap { $0.windowController as? ProjectWindowController }.first?.openFile(URL(fileURLWithPath: f))
                    }
                case "collapseAll": ed?.collapseAllFolds(nil)
                case "preview": ed?.showPreview(nil)
                case "worksheet": self.newWorksheet(nil)
                case "run": ed?.runWorksheetCommand(nil)
                case "blame": self.gitBlame(nil)
                case "clippings": if let menu = NSApp.mainMenu?.item(withTitle: "Clippings")?.submenu { self.rebuildClippingsMenu(menu) }
                case "complete": ed?.textView.complete(nil)
                case "end": ed?.textView.setSelectedRange(NSRange(location: (ed?.textView.string as NSString?)?.length ?? 0, length: 0))
                case let a where a.hasPrefix("type:"): ed?.textView.insertText(String(a.dropFirst(5)), replacementRange: ed!.textView.selectedRange())
                case let a where a.hasPrefix("line:"): ed?.textView.selectLine(Int(a.dropFirst(5)) ?? 1, column: 0, length: 0)
                default: break
                }
            }
            delay += 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.5) {
            for (i, window) in NSApp.windows.filter(\.isVisible).enumerated() {
                guard let view = window.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("\(i).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}

private extension NSMenuItem {
    func hiddenAlternate() -> NSMenuItem {
        isHidden = true
        allowsKeyEquivalentWhenHidden = true
        return self
    }
}
