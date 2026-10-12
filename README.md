# Quire

A fast, native macOS text and code editor by Ranbir Mazumdar.

## Introduction

Quire is a lightweight editor for the three kinds of files most people juggle every day: plain text, source code and Markdown. It is written in Swift on AppKit, so it starts instantly, follows the system's light and dark appearance, and behaves like a Mac app: window tabs, Open Recent, AppleScript and a `quire` command for the terminal.

**Writing code.** Syntax colouring for over 20 languages (more can be added as JSON language modules), code folding, a symbols menu, bracket balancing, word and keyword completion, and reusable clippings with placeholders. Git changes show in the gutter, and a Git menu covers blame, history, diffs, staging and commits.

**Working with text.** A large Text menu sorts, de-duplicates, wraps, re-cases and cleans up lines. Find and replace supports grep patterns with back-references and can search a whole folder. Any script in the Text Filters folder becomes a menu command that transforms the selection.

**Reading Markdown.** `⌥⌘P` opens a live preview pane beside the editor. It renders Mermaid diagrams (flowcharts, sequence, class, state, ER and C4 architecture diagrams), KaTeX math and syntax-highlighted code, and updates in place as you type. Everything is bundled, so it works offline.

**Projects and remote files.** Open a folder as a project with a sidebar of files and open documents, save it as a `.quireproject`, or edit files on a server over SFTP using your existing `ssh` setup.

**AI editing with your own model.** Connect Anthropic, OpenAI, Gemini or any OpenAI-compatible server, including local models through Ollama or LM Studio. Select text, press `⌘K`, type or dictate an instruction, and review the result before it replaces anything. API keys stay in your Keychain.

**Shell worksheets.** A `.worksheet` file runs lines in a persistent zsh session and inserts the output below them, so a document can double as a runnable notebook.

To install, download the latest signed and notarized `.dmg` from [Releases](https://github.com/ranbir/quire/releases), or build it from source as described below. Quire needs macOS 13 or later and runs natively on Apple silicon and Intel.

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
| Live preview | `⌥⌘P` (or the eye in the status bar) toggles a live Markdown/HTML/code preview pane to the right of the text (drag the divider to resize; the width is remembered). It updates in place as you type, keeps its scroll position, resolves relative images and can open in your browser. The built-in Markdown renderer covers headings, lists, task lists, tables, code blocks, links/references, emphasis and raw HTML. Bundled offline libraries add syntax-highlighted code blocks (highlight.js), math with `$…$`, `$$…$$` or ` ```math ` (KaTeX), and ` ```mermaid ` diagrams such as flowcharts, sequence, class, state, ER and C4 diagrams (Mermaid), all following light/dark mode. See `docs/preview-sample.md` |
| Shell worksheets | **File ▸ New Shell Worksheet** (or any `.worksheet` file). `⌘↩` runs the current line or selection in a persistent zsh (directory and variables carry over) and inserts the output below; `⌘.` stops it |
| Git | Gutter bars for added/modified/deleted lines vs `HEAD`, branch in the status bar, and a **Git** menu: Compare with HEAD, Blame, File History, Repository Status/Diff, Stage, Unstage, Discard Changes, Commit |
| SFTP / SSH | **File ▸ Open from SFTP Server** (`⌃⌘O`) browses a host over `ssh` (keys, agent, `~/.ssh/config`); files are edited locally and uploaded on every save (atomic, keeps permissions). Password and host-key prompts appear as Quire dialogs (Quire acts as its own `SSH_ASKPASS`); passwords are never stored |
| Language modules | JSON language definitions in `~/Library/Application Support/Quire/Language Modules` add or override languages (a Lua example is installed). **View ▸ Language ▸ Export Current Language as Module** gives a full template; **Reload Language Modules** applies changes |
| AI models (bring your own) | **Quire ▸ AI Models…** (`⌘,`) adds any number of providers: Anthropic, OpenAI, Google Gemini, OpenRouter, Groq, Mistral, DeepSeek, xAI, Together, Fireworks, or any OpenAI-compatible server — including local ones like Ollama, LM Studio, llama.cpp and vLLM. Each has a base URL, model (**Fetch Models** lists what the server offers), optional extra headers and **Test** button. API keys live in your Keychain; the provider list is plain JSON in `~/Library/Application Support/Quire/AI Providers.json`. Switch the active model from **AI ▸ Model** |
| AI editing | **AI ▸ Transform Selection…** (`⌘K`) sends the selection (or document) and an instruction to the active model, streams the result into a review sheet, and replaces the text only when you click **Replace** (undoable) |
| AppleScript | Scripting dictionary: a document's `text`, `selected text`, `source language`, `line count` and `posix path`; commands `replace … with … [in doc] [using grep]`, `select line` and `run worksheet command`, plus the standard suite. Example: `tell application "Quire" to replace "foo" with "bar" in front document` |

## Layout

```
Sources/QuireCore/   pure logic, unit-tested: codec, transforms, search, diff, tokenizer, languages, markdown, folding, git, shell, ssh, modules, AI providers
Sources/Quire/       AppKit app: documents, editor, projects, folding, preview, Git, SFTP, scripting
Resources/preview/   preview runtime (quire-preview.js/.css) and bundled Mermaid, KaTeX, highlight.js
Tests/               XCTest suite for QuireCore
bin/quire            command-line launcher
tools/make-icon.swift  generates the app icon
```

Syntax colouring is applied as layout-manager temporary attributes from a
background tokenizer, so it never touches the text storage, undo stack or
document dirty state.

## Testing

```sh
swift test                              # 67 unit tests for QuireCore
QUIRE_SELFTEST=1 .build/debug/Quire     # AppKit self-test
open -W --stdout /dev/stdout --env QUIRE_SELFTEST=1 -a build/Quire.app   # inside the bundle, adds AppleScript
```

## Limitations

- SFTP needs `ssh` access to the server and uses ssh's own authentication rather than a built-in SFTP client. It is unit-tested but hasn't been tested against a live server.
- The Markdown renderer covers the common parts of CommonMark/GFM, not the full spec.
- Folding uses heuristics (brackets, indentation, headings, tags) rather than a full parser.
