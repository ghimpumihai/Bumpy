import Foundation

/// Launch cleanup of session export zips left by builds before D51 (which had an in-app export).
enum FolderZipper {
    /// Where those builds put export zips, under tmp/, so cleanup can never touch anything else.
    static var defaultExportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
    }

    /// Removes export zips from a run that was killed with the share sheet open, plus zips that even
    /// older builds left directly in tmp/. Returns the number of files removed.
    @discardableResult
    static func removeStaleExports(exportDirectory: URL = defaultExportDirectory,
                                   legacyDirectory: URL = FileManager.default.temporaryDirectory) -> Int {
        let fm = FileManager.default
        var removed = 0
        for dir in [exportDirectory, legacyDirectory] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "zip" {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        return removed
    }
}
