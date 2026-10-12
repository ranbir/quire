import AppKit
import QuireCore

/// `Quire --export html|pdf input.md [-o output] [options]`: exports without opening a window
/// and exits. Reached through `quire --export …`.
enum CLIExport {
    static let usage = """
        usage: quire --export html|pdf input.md [-o output] [options]
          -o, --output PATH     where to write (default: input with .html or .pdf)
          --toc                 add a table of contents
          --title-page          PDF: title page from front matter
          --no-page-numbers     PDF: no page numbers
          --paper a4|letter     PDF paper size (default: the system's)
          --images embed|link|copy   HTML images (default: embed)
          --theme light|dark|auto    HTML colours (auto follows the reader's system)
          --link-urls           PDF: print link addresses after links
          --smart               curly quotes, dashes and ellipses
          --sanitize            remove unsafe raw HTML

        """

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("quire: \(message)\n".utf8))
        exit(2)
    }

    static func run(_ args: [String]) -> Never {
        var it = args.makeIterator()
        var format: String?, input: String?, output: String?, paper: String?
        var options = MarkdownExportOptions()
        while let a = it.next() {
            switch a {
            case "--export": format = it.next()?.lowercased()
            case "-o", "--output": output = it.next()
            case "--toc": options.tableOfContents = true
            case "--title-page": options.titlePage = true
            case "--no-page-numbers": options.pageNumbers = false
            case "--sanitize": options.sanitizeHTML = true
            case "--link-urls": options.linkAddresses = true
            case "--smart": options.smartPunctuation = true
            case "--theme":
                guard let v = it.next(), let t = MarkdownExportOptions.Theme(rawValue: v) else { fail("--theme takes light, dark or auto") }
                options.theme = t
            case "--paper": paper = it.next()?.lowercased()
            case "--images":
                guard let v = it.next(), let m = MarkdownExportOptions.Images(rawValue: v) else { fail("--images takes embed, link or copy") }
                options.images = m
            case "-h", "--help": print(usage, terminator: ""); exit(0)
            default:
                if a.hasPrefix("-") { fail("unknown option \(a)\n\(usage)") }
                input = a
            }
        }
        guard let format, ["html", "pdf"].contains(format) else { fail("--export takes html or pdf\n\(usage)") }
        guard let input else { fail("no input file\n\(usage)") }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let inURL = URL(fileURLWithPath: input, relativeTo: cwd).standardizedFileURL
        guard let data = try? Data(contentsOf: inURL) else { fail("can't read \(input)") }
        let outURL = output.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
            ?? inURL.deletingPathExtension().appendingPathExtension(format)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let exporter = MarkdownExporter(markdown: TextCodec.decode(data).text, fileURL: inURL, name: inURL.lastPathComponent, options: options)
        let finish: (Error?) -> Void = { error in
            if let error { fail(error.localizedDescription) }
            print(outURL.path)
            exit(0)
        }
        DispatchQueue.main.async {
            if format == "html" {
                exporter.exportHTML(to: outURL, finish)
            } else {
                let info = NSPrintInfo()
                switch paper {
                case "a4": info.paperSize = NSSize(width: 595, height: 842)
                case "letter": info.paperSize = NSSize(width: 612, height: 792)
                case nil: break
                default: fail("--paper takes a4 or letter")
                }
                exporter.exportPDF(to: outURL, printInfo: info, finish)
            }
        }
        app.run()
        exit(0)
    }
}
