import AppKit

/// A lazily loaded file-system tree node used by the project sidebar.
final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    private var cached: [FileNode]?

    init(url: URL) {
        self.url = url
        self.isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
    }

    static let skipped: Set<String> = [".git", ".svn", ".hg", ".build", "node_modules", "DerivedData", ".DS_Store"]

    var children: [FileNode] {
        if let cached { return cached }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let nodes = urls.filter { !Self.skipped.contains($0.lastPathComponent) }.map(FileNode.init).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        cached = nodes
        return nodes
    }

    func reloadRecursively() {
        cached?.forEach { $0.reloadRecursively() }
        cached = nil
    }
}
