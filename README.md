# Quire

A fast, native macOS text and code editor.

## Build & install

```sh
./build.sh              # builds build/Quire.app (universal, ad-hoc signed)
./build.sh --install    # also copies to /Applications and links the `quire` CLI
swift test              # runs the QuireCore unit tests
```

Requires macOS 13+ and the Swift 5.10+ toolchain (Xcode or Command Line Tools).

## Features

| Area | What you get |
|---|---|
| Documents | Window tabs, Open Recent, LF/CRLF/CR preserved on save, encoding detection (UTF-8/16 with or without BOM, Latin-1, Mac Roman, CP1252, Shift JIS…), changeable from the status bar, silent reload when the file changes on disk |
| Editor | Line-number gutter (click/drag to select lines), soft wrap, page guide, current-line highlight, show invisibles, auto-indent, auto-expand tabs, close-bracket outdent |
| Syntax colouring | Swift, C, C++, Objective-C, JavaScript, TypeScript, Python, Ruby, Shell, Go, Rust, Java/Kotlin, PHP, SQL, HTML, XML, CSS, Markdown, JSON, YAML, INI/TOML, Makefile. Detected from file extension, file name or `#!` line. Light and dark themes |
| Navigation | Symbols popup (functions, classes, headings), Go to Line (`⌘J`, accepts `line:col`), Balance brackets (`⌘B`) |
| Search | Find/replace with grep mode (`\1` back-references, `&` for the whole match), case/whole-word/wrap/selection-only options, Find All results window, multi-file search over a folder with file filters (`*.swift, *.m`), skipping `.git`, `node_modules`, binaries |
| Text menu | Change case (upper, lower, title, capitalize), sort lines (ascending, descending, numeric, case-sensitive), remove duplicate lines, reverse lines, keep/delete lines matching a pattern, prefix/suffix lines, add/remove line numbers, hard wrap, remove line breaks, strip trailing whitespace, zap gremlins, entab/detab, straighten/educate quotes, format JSON, un/comment, shift left/right, statistics |
| Line editing | Duplicate (`⇧⌘D`), delete (`⌃⇧K`), move up/down (`⌃⌘↑/↓`) |
| Unix filters | Any script in `~/Library/Application Support/Quire/Text Filters` shows up under **Text ▸ Text Filters**. It gets the selection (or whole document) on stdin and its stdout replaces it. **Run Shell Command on Selection** (`⌘\|`) does the same with an ad-hoc command |
| Compare | Compare the two front documents, a document against its saved version, or against any file, shown as a coloured unified diff |
| CLI | `quire file…`, `quire .`, `cmd \| quire` |
| Projects | **File ▸ Open Folder as Project** (`⇧⌘O`), **New Project**, or `quire .`. A sidebar lists open documents and project folders/files (drag in more, single-click to open); documents open inside the project window. Save as a `.quireproject` file, which remembers the items and open documents (paths stored relative to the project) |
| Code folding | Fold triangles in the gutter for braces, indentation (Python, YAML), Markdown headings and HTML/XML elements; **View ▸ Folding** folds the selection, collapses the enclosing block, or collapses/expands all. Folded text shows as a clickable `⋯`, and folds follow edits |
| Completion | `⌥⎋` completes from the document's words and the language's keywords; optional **Auto-Complete as You Type** |
| Clippings | **Clippings** menu with per-language and Universal snippets from `~/Library/Application Support/Quire/Clippings`. Tokens: `#SELECTION#`, `#INSERTION#`, `#CLIPBOARD#`, `#DATE#`, `#TIME#`, `#FILENAME#`, `#BASENAME#`, and `<#placeholders#>` (`⌃/` jumps to the next one). Inserted clippings match the current indentation |
| Live preview | `⌥⌘P` opens a live Markdown/HTML preview that updates as you type, keeps its scroll position, resolves relative images and can open in your browser. The built-in Markdown renderer covers headings, lists, task lists, tables, code blocks, links/references, emphasis and raw HTML |
| Shell worksheets | **File ▸ New Shell Worksheet** (or any `.worksheet` file). `⌘↩` runs the current line or selection in a persistent zsh (directory and variables carry over) and inserts the output below; `⌘.` stops it |
| Git | Gutter bars for added/modified/deleted lines vs `HEAD`, branch in the status bar, and a **Git** menu: Compare with HEAD, Blame, File History, Repository Status/Diff, Stage, Unstage, Discard Changes, Commit |
| SFTP / SSH | **File ▸ Open from SFTP Server** (`⌃⌘O`) browses a host over `ssh` (keys, agent, `~/.ssh/config`); files are edited locally and uploaded on every save (atomic, keeps permissions). Password and host-key prompts appear as Quire dialogs (Quire acts as its own `SSH_ASKPASS`); passwords are never stored |
| Language modules | JSON language definitions in `~/Library/Application Support/Quire/Language Modules` add or override languages (a Lua example is installed). **View ▸ Language ▸ Export Current Language as Module** gives a full template; **Reload Language Modules** applies changes |
| AppleScript | Scripting dictionary: a document's `text`, `selected text`, `source language`, `line count` and `posix path`; commands `replace … with … [in doc] [using grep]`, `select line` and `run worksheet command`, plus the standard suite. Example: `tell application "Quire" to replace "foo" with "bar" in front document` |

## Layout

```
Sources/QuireCore/   pure logic, unit-tested: codec, transforms, search, diff, tokenizer, languages, markdown, folding, git, shell, ssh, modules
Sources/Quire/       AppKit app: documents, editor, projects, folding, preview, Git, SFTP, scripting
Tests/               XCTest suite for QuireCore
bin/quire            command-line launcher
tools/make-icon.swift  generates the app icon
```

Syntax colouring is applied as layout-manager temporary attributes from a
background tokenizer, so it never touches the text storage, undo stack or
document dirty state.

## Testing

```sh
swift test                              # 47 unit tests for QuireCore
QUIRE_SELFTEST=1 .build/debug/Quire     # AppKit self-test (52 checks)
open -W --stdout /dev/stdout --env QUIRE_SELFTEST=1 -a build/Quire.app   # inside the bundle, adds AppleScript (55 checks)
```

## Limitations

- SFTP needs `ssh` access to the server and uses ssh's own authentication rather than a built-in SFTP client. It is unit-tested but hasn't been tested against a live server.
- The Markdown renderer covers the common parts of CommonMark/GFM, not the full spec.
- Folding uses heuristics (brackets, indentation, headings, tags) rather than a full parser.
