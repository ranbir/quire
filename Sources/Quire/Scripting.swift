import AppKit
import QuireCore

/// Shared helpers for the AppleScript commands in Quire.sdef.
private extension NSScriptCommand {
    var targetDocument: Document? {
        (evaluatedArguments?["target"] as? Document) ?? NSApp.activeEditor?.doc
            ?? NSDocumentController.shared.documents.compactMap { $0 as? Document }.first
    }

    func fail(_ message: String, code: Int = errOSAGeneralError) -> Any? {
        scriptErrorNumber = code
        scriptErrorString = message
        return nil
    }
}

@objc(QuireReplaceCommand)
final class ReplaceCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let pattern = directParameter as? String, !pattern.isEmpty else { return fail("Missing search text.", code: errAEParamMissed) }
        guard let replacement = evaluatedArguments?["replacement"] as? String else { return fail("Missing “with” text.", code: errAEParamMissed) }
        guard let doc = targetDocument else { return fail("No document is open.") }
        let grep = evaluatedArguments?["grep"] as? Bool ?? false
        let opts = SearchOptions(pattern: pattern, caseSensitive: evaluatedArguments?["caseSensitive"] as? Bool ?? false, grep: grep)
        let regex: NSRegularExpression
        do { regex = try SearchEngine.regex(for: opts) } catch { return fail("Invalid pattern: \(error.localizedDescription)") }
        let tv = doc.editor.textView
        let all = NSRange(location: 0, length: (tv.string as NSString).length)
        let count = regex.numberOfMatches(in: tv.string, range: all)
        if count > 0 {
            let out = regex.stringByReplacingMatches(in: tv.string, range: all, withTemplate: SearchEngine.replacementTemplate(replacement, grep: grep))
            tv.replace(all, with: out, select: false)
        }
        return count
    }
}

@objc(QuireSelectLineCommand)
final class SelectLineCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let line = directParameter as? Int else { return fail("Expected a line number.", code: errAEParamMissed) }
        guard let doc = targetDocument else { return fail("No document is open.") }
        doc.editor.textView.selectLine(line, column: 0, length: 0, selectWholeLine: true)
        return nil
    }
}

@objc(QuireRunShellCommand)
final class RunShellCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let command = directParameter as? String else { return fail("Expected shell text.", code: errAEParamMissed) }
        guard let doc = targetDocument else { return fail("No document is open.") }
        do {
            let out = try doc.shell.run(command, timeout: 120)
            return out.text
        } catch {
            return fail(error.localizedDescription)
        }
    }
}

@objc(QuireExportCommand)
final class ExportCommand: NSScriptCommand {
    /// `export as PDF to …` with no document: the front one.
    override func performDefaultImplementation() -> Any? {
        guard let doc = targetDocument else { return fail("No document is open.") }
        return doc.handleExportScriptCommand(self)
    }

    /// Exports `doc`, suspending the script until the file is written.
    func export(_ doc: Document) -> Any? {
        guard let url = evaluatedArguments?["destination"] as? URL else { return fail("Missing “to” file.", code: errAEParamMissed) }
        guard doc.editor.textView.language.name == "Markdown" else { return fail("Only Markdown documents can be exported.") }
        let pdf = (evaluatedArguments?["format"] as? NSNumber)?.uint32Value == 0x5145_7850   // 'QExP'
        var options = ExportPrefs.load()
        if let toc = evaluatedArguments?["toc"] as? Bool { options.tableOfContents = toc }
        let exporter = MarkdownExporter(markdown: doc.editor.textView.string, fileURL: doc.fileURL, name: doc.displayName, options: options)
        let finish: (Error?) -> Void = { [self] error in
            if let error {
                scriptErrorNumber = errOSAGeneralError
                scriptErrorString = error.localizedDescription
            }
            resumeExecution(withResult: nil)
        }
        suspendExecution()
        if pdf { exporter.exportPDF(to: url, printInfo: doc.printInfo, finish) } else { exporter.exportHTML(to: url, finish) }
        return nil
    }
}

extension Document {
    /// `export document "x.md" as PDF to …` arrives here (sdef `responds-to`).
    @objc func handleExportScriptCommand(_ command: NSScriptCommand) -> Any? {
        (command as? ExportCommand)?.export(self)
    }
}
