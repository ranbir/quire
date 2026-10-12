import AppKit
import QuireCore

/// Clippings live in ~/Library/Application Support/Quire/Clippings/<Language>/
/// plus a "Universal" folder shown for every language. Subfolders become submenus.
enum ClippingsLibrary {
    static var folder: URL { Prefs.supportFolder.appendingPathComponent("Clippings") }
    static let universal = "Universal"

    static func folderName(for language: String) -> String {
        language.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    static func ensureFolder() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        let seeds: [String: [(String, String)]] = [
            universal: [
                ("Date Stamp.txt", "#DATE#"),
                ("Time Stamp.txt", "#TIME#"),
                ("TODO.txt", "TODO: #INSERTION#"),
                ("Wrap in Quotes.txt", "“#SELECTION##INSERTION#”"),
            ],
            "Swift": [
                ("func.swift", "func <#name#>(<#parameters#>) -> <#Type#> {\n    #SELECTION#<#body#>\n}\n"),
                ("guard let.swift", "guard let <#name#> = <#value#> else { <#return#> }"),
                ("if.swift", "if <#condition#> {\n    #SELECTION#<#code#>\n}\n"),
                ("Task.swift", "Task {\n    #SELECTION#<#await work()#>\n}\n"),
                ("MARK.swift", "// MARK: - <#Section#>"),
            ],
            "Python": [
                ("def.py", "def <#name#>(<#args#>):\n    #SELECTION#<#pass#>\n"),
                ("class.py", "class <#Name#>:\n    def __init__(self<#, args#>):\n        <#pass#>\n"),
                ("main guard.py", "if __name__ == \"__main__\":\n    <#main()#>\n"),
            ],
            "JavaScript": [
                ("function.js", "function <#name#>(<#params#>) {\n  #SELECTION#<#body#>\n}\n"),
                ("arrow.js", "const <#name#> = (<#params#>) => {\n  #SELECTION#<#body#>\n};\n"),
                ("console.log.js", "console.log(#SELECTION##INSERTION#);"),
            ],
            "HTML": [
                ("Document.html", "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\">\n  <title><#Title#></title>\n</head>\n<body>\n  #SELECTION##INSERTION#\n</body>\n</html>\n"),
                ("Link.html", "<a href=\"<#url#>\">#SELECTION#</a>"),
                ("Strong.html", "<strong>#SELECTION##INSERTION#</strong>"),
                ("Div.html", "<div class=\"<#class#>\">\n  #SELECTION#\n</div>\n"),
            ],
            "Markdown": [
                ("Link.md", "[#SELECTION#](<#url#>)"),
                ("Image.md", "![<#alt text#>](<#path#>)"),
                ("Code Block.md", "```<#language#>\n#SELECTION#\n```\n"),
                ("Table.md", "| <#Column#> | <#Column#> |\n|---|---|\n| <#cell#> | <#cell#> |\n"),
            ],
            "Shell Script": [
                ("if.sh", "if [ <#condition#> ]; then\n    #SELECTION#<#commands#>\nfi\n"),
                ("for.sh", "for <#item#> in <#list#>; do\n    #SELECTION#<#commands#>\ndone\n"),
                ("strict mode.sh", "set -euo pipefail\n"),
            ],
        ]
        for (group, items) in seeds {
            let dir = folder.appendingPathComponent(group)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in items {
                try? body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
    }

    /// Adds items for `dir` to `menu`, recursing into subfolders.
    static func addItems(from dir: URL, to menu: NSMenu, action: Selector, target: AnyObject) {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                let sub = NSMenu(title: url.lastPathComponent)
                addItems(from: url, to: sub, action: action, target: target)
                let item = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
                item.submenu = sub
                menu.addItem(item)
            } else {
                let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: action, keyEquivalent: "")
                item.target = target
                item.representedObject = url
                menu.addItem(item)
            }
        }
    }
}

/// User language modules: JSON files in ~/Library/Application Support/Quire/Language Modules.
enum LanguageModulesLibrary {
    static var folder: URL { Prefs.supportFolder.appendingPathComponent("Language Modules") }

    static func ensureFolder() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let lua = """
        {
          "name": "Lua",
          "extensions": ["lua"],
          "shebangs": ["lua"],
          "lineComment": "--",
          "blockComment": ["--[[", "]]"],
          "keywords": ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
                       "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "self"],
          "types": ["string", "table", "math", "io", "os", "coroutine"],
          "rules": [
            { "pattern": "--\\\\[\\\\[[\\\\s\\\\S]*?(?:\\\\]\\\\]|\\\\z)", "kind": "comment" },
            { "pattern": "--.*", "kind": "comment" },
            { "pattern": "\\\\[\\\\[[\\\\s\\\\S]*?(?:\\\\]\\\\]|\\\\z)", "kind": "string" },
            { "pattern": "\\"(?:\\\\\\\\.|[^\\"\\\\\\\\\\\\n])*\\"?", "kind": "string" },
            { "pattern": "'(?:\\\\\\\\.|[^'\\\\\\\\\\\\n])*'?", "kind": "string" }
          ],
          "symbolPatterns": ["^[ \\\\t]*(?:local[ \\\\t]+)?function[ \\\\t]+([\\\\w.:]+)"],
          "indentAfter": "{(["
        }

        """
        try? lua.write(to: folder.appendingPathComponent("Lua.json"), atomically: true, encoding: .utf8)
        let readme = """
        Language modules for Quire
        ==========================

        Each *.json file here defines a language (or overrides a built-in one with the
        same name). Use View ▸ Language ▸ Export Current Language as Module… to get a
        complete example, edit it, then choose Reload Language Modules.

        Keys: name, extensions, filenames, shebangs, keywords, types, lineComment,
        blockComment ([open, close]), caseInsensitiveKeywords, capitalizedAreTypes,
        highlightNumbers, indentAfter (characters), symbolPatterns (regexes whose
        first group is the symbol name), and rules: [{pattern, kind, inner?}] where
        kind is one of keyword, type, string, comment, number, preprocessor, tag,
        attribute, variable, heading, emphasis, link.

        """
        try? readme.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    static func reload() -> [String] {
        ensureFolder()
        let errors = Languages.loadModules(from: folder)
        NotificationCenter.default.post(name: .languagesChanged, object: nil)
        return errors
    }
}
